%%% @author zhongwen <zhongwencool@gmail.com>
-module(observer_cli).

-include("observer_cli.hrl").

%% API
-export([start/0]).
-export([start/1]).
-export([start/2]).

-define(CPU_ALARM_THRESHOLD, 0.8). %% cpu >= this value will be highlight
-define(COUNT_ALARM_THRESHOLD, 0.85). %% port or process reach max_limit * 0.85 will be highlight
-define(LAST_LINE, "q(quit) p(pause) r/rr(reduction) " ++
    "m/mm(mem) b/bb(binary mem) t/tt(total heap size) mq/mmq(msg queue) 9(proc 9 info) pd/pu(page:down/up)").

-define(STABLE_SYSTEM_KEY, [system_version, process_limit, smp_support,
    port_limit, ets_limit, logical_processors, multi_scheduling]).

-spec start() -> no_return.
start() -> start(#view_opts{}).

-spec start(Node) -> no_return when Node :: atom().
start(Node) when Node =:= node() -> start(#view_opts{});
start(Node) when is_atom(Node) -> rpc_start(Node);
start(#view_opts{home = Home} = Opts) ->
    erlang:process_flag(trap_exit, true),
    AutoRow = check_auto_row(),
    StorePid = observer_cli_store:start(),
    LastSchWallFlag = erlang:system_flag(scheduler_wall_time, true),
    RenderPid = spawn_link(fun() -> render_worker(StorePid, Home, AutoRow) end),
    manager(StorePid, RenderPid, Opts#view_opts{auto_row = AutoRow}, LastSchWallFlag).

-spec start(Node, Cookies | Options) -> no_return when
    Node :: atom(),
    Cookies :: atom(),
    Options :: proplists:proplist().
start(Node, _Cookie) when Node =:= node() -> start(#view_opts{});
start(Node, Cookie) when is_atom(Node) andalso is_atom(Cookie) ->
    start(Node, [{cookie, Cookie}]);
start(Node, Options) when is_atom(Node) andalso is_list(Options) ->
    case proplists:get_value(cookie, Options) of
        undefined -> ok;
        Cookie -> erlang:set_cookie(Node, Cookie)
    end,
    rpc_start(Node).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Private
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

rpc_start(Node) ->
    case net_kernel:hidden_connect_node(Node) of
        true -> rpc:call(Node, ?MODULE, start, [#view_opts{}]);
        false -> connect_error(<<"Node(~p) refuse to be connected, make sure cookie is valid~n">>, Node);
        ignored -> connect_error(<<"Ignored by node(~p), local node is not alive!~n">>, Node)
    end.

manager(StorePid, RenderPid, Opts, LastSchWallFlag) ->
    #view_opts{home = Home = #home{cur_page = CurPage, pages = Pages}} = Opts,
    case observer_cli_lib:parse_cmd(Opts, [RenderPid, StorePid]) of
        quit ->
            erlang:send(RenderPid, quit),
            erlang:system_flag(scheduler_wall_time, LastSchWallFlag),
            observer_cli_lib:exit_processes([StorePid]),
            quit;
        pause_or_resume ->
            erlang:send(RenderPid, pause_or_resume),
            manager(StorePid, RenderPid, Opts, LastSchWallFlag);
        {new_interval, NewInterval} ->
            observer_cli_lib:exit_processes([StorePid, RenderPid]),
            erlang:system_flag(scheduler_wall_time, LastSchWallFlag),
            start(Opts#view_opts{home = Home#home{interval = NewInterval}});
        {jump, NewPos} ->
            NewPages = observer_cli_lib:update_page_pos(CurPage, NewPos, Pages),
            NewHome = Home#home{pages = NewPages},
            start_process_view(StorePid, RenderPid, Opts#view_opts{home = NewHome}, LastSchWallFlag, false);
        jump ->
            start_process_view(StorePid, RenderPid, Opts, LastSchWallFlag, true);
        {func, Func, Type} ->
            observer_cli_lib:exit_processes([StorePid, RenderPid]),
            erlang:system_flag(scheduler_wall_time, LastSchWallFlag),
            start(Opts#view_opts{home = Home#home{func = Func, type = Type}});
        page_down_top_n ->
            NewPage = max(CurPage + 1, 1),
            NewPages = observer_cli_lib:update_page_pos(StorePid, NewPage, Pages),
            observer_cli_lib:exit_processes([StorePid, RenderPid]),
            erlang:system_flag(scheduler_wall_time, LastSchWallFlag),
            start(Opts#view_opts{home = Home#home{cur_page = NewPage, pages = NewPages}});
        page_up_top_n ->
            NewPage = max(CurPage - 1, 1),
            NewPages = observer_cli_lib:update_page_pos(StorePid, NewPage, Pages),
            observer_cli_lib:exit_processes([StorePid, RenderPid]),
            erlang:system_flag(scheduler_wall_time, LastSchWallFlag),
            start(Opts#view_opts{home = Home#home{cur_page = NewPage, pages = NewPages}});
        _ ->
            manager(StorePid, RenderPid, Opts, LastSchWallFlag)
    end.

render_worker(Manager, #home{} = Home, AutoRow) ->
    ?output(?CLEAR),
    StableInfo = get_stable_system_info(),
    LastStats = get_incremental_stats(),
    redraw_running(Manager, Home, StableInfo, LastStats, erlang:make_ref(), AutoRow, true).

%% pause status waiting to be resume
redraw_pause(StorePid, #home{func = Func, type = Type} = Home, StableInfo, LastStats, LastTimeRef, AutoRow) ->
    notify_pause_status(),
    erlang:cancel_timer(LastTimeRef),
    receive
        quit -> quit;
        {Func, Type} -> redraw_running(StorePid, Home, StableInfo, LastStats, LastTimeRef, AutoRow, false);
        pause_or_resume ->
            ?output(?CLEAR),
            redraw_running(StorePid, Home, StableInfo, LastTimeRef, LastTimeRef, AutoRow, true)
    end.

%% running status
redraw_running(StorePid, #home{interval = Interval, func = Func,
    type = Type, pages = RankPos, cur_page = CurPage} = Home,
    StableInfo, LastStats, LastTimeRef, AutoRow, IsFirstTime) ->
    erlang:cancel_timer(LastTimeRef),
    TerminalRow = observer_cli_lib:get_terminal_rows(AutoRow),
    {{Processes, Schedulers}, NewStats} = node_stats(LastStats),
    {CPURow, CPULine} = render_scheduler_usage(Schedulers),
    ProcessRows = max(TerminalRow - 14 - CPURow, 0),
    TopList = get_top_n(Func, Type, Interval, ProcessRows * CurPage, IsFirstTime),
    {UseMemInt, AllocatedMemInt, UnusedMemInt} = get_change_system_info(),
    AtomStatus = get_atom_status(),
    Text = get_refresh_prompt(Func, Type, Interval, ProcessRows),
    MenuLine = observer_cli_lib:render_menu(home, Text),
    SystemLine = render_system_line(StableInfo, AtomStatus, UseMemInt, AllocatedMemInt, UnusedMemInt, Processes),
    MemLine = render_memory_process_line(Processes, Schedulers, Interval),
    {TopNList, RankLine} = render_top_n_view(Type, TopList, ProcessRows, RankPos, CurPage),
    LastLine = observer_cli_lib:render_last_line(?LAST_LINE),
    ?output([?CURSOR_TOP, MenuLine, SystemLine, MemLine, CPULine, RankLine, LastLine]),
    
    observer_cli_store:update(StorePid, ProcessRows, TopNList),
    TimeRef = refresh_next_time(Func, Type, Interval),
    receive
        quit -> quit;
        pause_or_resume -> redraw_pause(StorePid, Home, StableInfo, NewStats, TimeRef, AutoRow);
        {Func, Type} -> redraw_running(StorePid, Home, StableInfo, NewStats, TimeRef, AutoRow, false)
    end.

render_system_line(StableInfo, AtomStatus, UseMem, AllocatedMem, UnusedMem, ProcSum) ->
    [Version, ProcLimit, SmpSupport, PortLimit, EtsLimit, LogicalProc, MultiScheduling] = StableInfo,
    UsePercent = observer_cli_lib:to_percent(UseMem / AllocatedMem),
    UnUsePercent = observer_cli_lib:to_percent(UnusedMem / AllocatedMem),
    {PortWarning, ProcWarning, PortCount, ProcCount} = get_port_proc_info(PortLimit, ProcLimit, ProcSum),
    Title = ?render([
        ?W(Version -- "\n", 136),
        ?NEW_LINE,
        ?GRAY_BG,
        ?W("System", 10), ?W("Count/Limit", 21),
        ?W("System Switch", 25), ?W("Status", 21),
        ?W("Memory Info", 20), ?W("Size", 24)]),
    Row1 = ?render([
        ?W("Proc Count", 10), ?W2(ProcWarning, ProcCount, 22),
        ?W(" Smp Support", 26), ?W(SmpSupport, 21),
        ?W("Allocted Mem", 20), ?W({byte, AllocatedMem}, 15), ?W("100.0%", 6),
        ?NEW_LINE,
        ?W("Port Count", 10), ?W2(PortWarning, PortCount, 22),
        ?W(" Multi Scheduling", 26), ?W(MultiScheduling, 21),
        ?W("Use Mem", 20), ?W({byte, UseMem}, 15), ?W(UsePercent, 6)]),
    Row2 =
        case AtomStatus of
            {ok, AtomLimit, AtomCount} ->
                {AtomWarning, Atom} = format_atom_info(AtomLimit, AtomCount),
                ?render([
                    ?UNDERLINE, ?W("Atom Count", 10), ?W2(AtomWarning, Atom, 22),
                    ?W(" Logical Processors", 26), ?W(LogicalProc, 21),
                    ?W("Unuse Mem", 20), ?W({byte, UnusedMem}, 15), ?W(UnUsePercent, 6)
                ]);
            {error, unsupported} ->
                ?render([
                    ?UNDERLINE, ?W("Ets Limit", 10), ?W(EtsLimit, 21),
                    ?W("Logical Processors", 25), ?W(LogicalProc, 21),
                    ?W("Unuse Mem", 20), ?W({byte, UnusedMem}, 15), ?W(UnUsePercent, 6)
                ])
        end,
    [Title, Row1, Row2].

render_memory_process_line(ProcSum, MemSum, Interval) ->
    CodeMem = erlang:memory(code),
    [
        {process_count, _ProcC},
        {run_queue, RunQ},
        {memory_total, TotalMem},
        {memory_procs, ProcMem},
        {memory_atoms, AtomMem},
        {memory_bin, BinMem},
        {memory_ets, EtsMem}|_
    ] = ProcSum,
    [
        {bytes_in, BytesIn},
        {bytes_out, BytesOut},
        {gc_count, GcCount},
        {gc_words_reclaimed, GcWordsReclaimed},
        {reductions, Reductions}|_
    ] = MemSum,
    
    {Queue, LogKey} =
        case whereis(error_logger) of
            undefined ->
                {erlang:integer_to_list(RunQ), "RunQueue"};
            Pid ->
                {_, Q} = process_info(Pid, message_queue_len),
                {erlang:integer_to_list(RunQ) ++ "/" ++ erlang:integer_to_list(Q),
                    "RunQueue/ErrorLoggerQueue"}
        end,
    ProcMemPercent = observer_cli_lib:to_percent(ProcMem / TotalMem),
    AtomMemPercent = observer_cli_lib:to_percent(AtomMem / TotalMem),
    BinMemPercent = observer_cli_lib:to_percent(BinMem / TotalMem),
    CodeMemPercent = observer_cli_lib:to_percent(CodeMem / TotalMem),
    EtsMemPercent = observer_cli_lib:to_percent(EtsMem / TotalMem),
    
    Title = ?render([
        ?GRAY_BG, ?W("Mem Type", 10), ?W("Size", 21),
        ?W("Mem Type", 25), ?W("Size", 21),
        ?W("IO/GC", 20), ?W(["Interval: ", erlang:integer_to_binary(Interval), "ms"], 24)
        ]),
    Row = ?render([
        ?W("Total", 10), ?W({byte, TotalMem}, 12), ?W("100.0%", 6),
        ?W("Binary", 25), ?W({byte, BinMem}, 12), ?W(BinMemPercent, 6),
        ?W("IO Output", 20), ?W({byte, BytesOut}, 24),
        ?NEW_LINE,
        ?W("Process", 10), ?W({byte, ProcMem}, 12), ?W(ProcMemPercent, 6),
        ?W("Code", 25), ?W({byte, CodeMem}, 12), ?W(CodeMemPercent, 6),
        ?W("IO Input", 20), ?W({byte, BytesIn}, 24),
        ?NEW_LINE,
        ?W("Atom", 10), ?W({byte, AtomMem}, 12), ?W(AtomMemPercent, 6),
        ?W("Reductions", 25), ?W(Reductions, 21),
        ?W("Gc Count", 20), ?W(GcCount, 24),
        ?NEW_LINE,
        ?W("Ets", 10), ?W({byte, EtsMem}, 12), ?W(EtsMemPercent, 6),
        ?W(LogKey, 25), ?W(Queue, 21),
        ?W("Gc Words Reclaimed", 20), ?W(GcWordsReclaimed, 24)]),
    [Title, Row].

render_scheduler_usage(MemSum) ->
    SchedulerUsage = proplists:get_value(scheduler_usage, MemSum),
    SchedulerNum = erlang:length(SchedulerUsage),
    render_scheduler_usage(SchedulerUsage, SchedulerNum).

%% < 8 core will split 2 part
render_scheduler_usage(SchedulerUsage, SchedulerNum) when SchedulerNum < 8 ->
    HalfSchedulerNum = SchedulerNum div 2,
    CPU =
        [begin
             Seq2 = Seq1 + HalfSchedulerNum,
             Percent1 = proplists:get_value(Seq1, SchedulerUsage),
             Percent2 = proplists:get_value(Seq2, SchedulerUsage),
             CPU1 = observer_cli_lib:to_percent(Percent1),
             CPU2 = observer_cli_lib:to_percent(Percent2),
             Process1 = lists:duplicate(trunc(Percent1 * 57), "|"),
             Process2 = lists:duplicate(trunc(Percent2 * 57), "|"),
             IsLastLine = Seq1 =:= HalfSchedulerNum,
             Format = process_bar_format_style(Percent1, Percent2, IsLastLine),
             io_lib:format(Format, [
                 Seq1, Process1, CPU1,
                 Seq2, Process2, CPU2
             ])
         end || Seq1 <- lists:seq(1, HalfSchedulerNum)],
    {HalfSchedulerNum, CPU};
%% >= 8 will split 4 part
render_scheduler_usage(SchedulerUsage, SchedulerNum) ->
    PosSchedulerNum = SchedulerNum div 4,
    CPU =
        [begin
             Seq2 = Seq1 + PosSchedulerNum,
             Seq3 = Seq2 + PosSchedulerNum,
             Seq4 = Seq3 + PosSchedulerNum,
             Percent1 = proplists:get_value(Seq1, SchedulerUsage),
             Percent2 = proplists:get_value(Seq2, SchedulerUsage),
             Percent3 = proplists:get_value(Seq3, SchedulerUsage),
             Percent4 = proplists:get_value(Seq4, SchedulerUsage),
             CPU1 = observer_cli_lib:to_percent(Percent1),
             CPU2 = observer_cli_lib:to_percent(Percent2),
             CPU3 = observer_cli_lib:to_percent(Percent3),
             CPU4 = observer_cli_lib:to_percent(Percent4),
             Process1 = lists:duplicate(trunc(Percent1 * 22), "|"),
             Process2 = lists:duplicate(trunc(Percent2 * 22), "|"),
             Process3 = lists:duplicate(trunc(Percent3 * 22), "|"),
             Process4 = lists:duplicate(trunc(Percent4 * 23), "|"),
             IsLastLine = Seq1 =:= PosSchedulerNum,
             Format = process_bar_format_style(Percent1, Percent2, Percent3, Percent4, IsLastLine),
             io_lib:format(Format, [
                 Seq1, Process1, CPU1,
                 Seq2, Process2, CPU2,
                 Seq3, Process3, CPU3,
                 Seq4, Process4, CPU4
             ])
         end || Seq1 <- lists:seq(1, PosSchedulerNum)],
    {PosSchedulerNum, CPU}.

render_top_n_view(memory, MemoryList, Num, Pages, Page) ->
    Title = ?render([
        ?W2(?GRAY_BG, "No | Pid", 16), ?W2(?RED_BG, "     Memory", 14), ?W(?GRAY_BG, "Name or Initial Call", 38),
        ?W(?GRAY_BG, "           Reductions", 21), ?W(?GRAY_BG, " MsgQueue", 10), ?W(?GRAY_BG, "Current Function", 32)
    ]),
    {Start, ChoosePos} = observer_cli_lib:get_pos(Page, Num, Pages, erlang:length(MemoryList)),
    FormatFunc =
        fun(Item, {Acc, Acc1, Pos}) ->
            {Pid, MemVal, CurFun, NameOrCall} = get_top_n_info(Item),
            {Reductions, MsgQueueLen} = get_pid_info(Pid, [reductions, message_queue_len]),
            Format = get_memory_format(ChoosePos, Pos),
            R = io_lib:format(Format,
                [
                    Pos, erlang:pid_to_list(Pid),
                    observer_cli_lib:to_byte(MemVal), NameOrCall,
                    observer_cli_lib:to_list(Reductions),
                    observer_cli_lib:to_list(MsgQueueLen), CurFun
                ]),
            {[R|Acc], [{Pos, Pid}|Acc1], Pos + 1}
        end,
    {Rows, PidList} = top_n_rows(FormatFunc, Start, lists:sublist(MemoryList, Start, Num)),
    {PidList, [Title | lists:reverse(Rows)]};
render_top_n_view(binary_memory, MemoryList, Num, Pages, Page) ->
    Title = ?render([
        ?W2(?GRAY_BG, "No | Pid", 16), ?W2(?RED_BG, "  BinMemory", 14), ?W(?GRAY_BG, "Name or Initial Call", 38),
        ?W(?GRAY_BG, "           Reductions", 21), ?W(?GRAY_BG, " MsgQueue", 10), ?W(?GRAY_BG, "Current Function", 32)
    ]),
    {Start, ChoosePos} = observer_cli_lib:get_pos(Page, Num, Pages, erlang:length(MemoryList)),
    FormatFunc =
        fun(Item, {Acc, Acc1, Pos}) ->
            {Pid, MemVal, CurFun, NameOrCall} = get_top_n_info(Item),
            {Reductions, MsgQueueLen} = get_pid_info(Pid, [reductions, message_queue_len]),
            Format = get_memory_format(ChoosePos, Pos),
            R = io_lib:format(Format,
                [
                    Pos, pid_to_list(Pid),
                    observer_cli_lib:to_byte(MemVal), NameOrCall,
                    observer_cli_lib:to_list(Reductions),
                    observer_cli_lib:to_list(MsgQueueLen), CurFun
                ]),
            {[R | Acc], [{Pos, Pid} | Acc1], Pos + 1}
        end,
    {Rows, PidList} = top_n_rows(FormatFunc, Start, lists:sublist(MemoryList, Start, Num)),
    {PidList, [Title | lists:reverse(Rows)]};
render_top_n_view(reductions, ReductionList, Num, Pages, Page) ->
    Title = ?render([
        ?W2(?GRAY_BG, "No | Pid", 16), ?W2(?RED_BG, "     Reductions", 21), ?W(?GRAY_BG, "Name or Initial Call", 38),
        ?W(?GRAY_BG, "      Memory", 13), ?W(?GRAY_BG, " MsgQueue", 10), ?W(?GRAY_BG, "Current Function", 33)
    ]),
    {Start, ChoosePos} = observer_cli_lib:get_pos(Page, Num, Pages, erlang:length(ReductionList)),
    FormatFunc =
        fun(Item, {Acc, Acc1, Pos}) ->
            {Pid, Reductions, CurFun, NameOrCall} = get_top_n_info(Item),
            {Memory, MsgQueueLen} = get_pid_info(Pid, [memory, message_queue_len]),
            Format = get_reduction_format(ChoosePos, Pos),
            R = io_lib:format(Format,
                [
                    Pos, pid_to_list(Pid),
                    observer_cli_lib:to_list(Reductions), NameOrCall,
                    observer_cli_lib:to_byte(Memory),
                    observer_cli_lib:to_list(MsgQueueLen), CurFun
                ]),
            {[R|Acc], [{Pos, Pid}|Acc1], Pos + 1}
        end,
    {Rows, PidList} = top_n_rows(FormatFunc, Start, lists:sublist(ReductionList, Start, Num)),
    {PidList, [Title | lists:reverse(Rows)]};
render_top_n_view(total_heap_size, HeapList, Num, Pages, Page) ->
    Title = ?render([
        ?W2(?GRAY_BG, "No | Pid", 16), ?W2(?RED_BG, " TotalHeapSize", 14), ?W(?GRAY_BG, "Name or Initial Call", 38),
        ?W(?GRAY_BG, "           Reductions", 21), ?W(?GRAY_BG, " MsgQueue", 10), ?W(?GRAY_BG, "Current Function", 32)
    ]),
    {Start, ChoosePos} = observer_cli_lib:get_pos(Page, Num, Pages, erlang:length(HeapList)),
    FormatFunc =
        fun(Item, {Acc, Acc1, Pos}) ->
            {Pid, HeapSize, CurFun, NameOrCall} = get_top_n_info(Item),
            {Reductions, MsgQueueLen} = get_pid_info(Pid, [reductions, message_queue_len]),
            Format = get_memory_format(ChoosePos, Pos),
            R = io_lib:format(Format,
                [
                    Pos, pid_to_list(Pid),
                    observer_cli_lib:to_byte(HeapSize), NameOrCall,
                    observer_cli_lib:to_list(Reductions),
                    observer_cli_lib:to_list(MsgQueueLen), CurFun
                ]),
            {[R|Acc], [{Pos, Pid}|Acc1], Pos + 1}
        end,
    {Rows, PidList} = top_n_rows(FormatFunc, Start, lists:sublist(HeapList, Start, Num)),
    {PidList, [Title | lists:reverse(Rows)]};
render_top_n_view(message_queue_len, MQLenList, Num, Pages, Page) ->
    Title = ?render([
        ?W2(?GRAY_BG, "No | Pid", 16), ?W2(?RED_BG, " MsgQueue", 11), ?W(?GRAY_BG, "Name or Initial Call", 37),
        ?W(?GRAY_BG, "      Memory", 13), ?W(?GRAY_BG, " Reductions", 21), ?W(?GRAY_BG, "Current Function", 33)
    ]),
    {Start, ChoosePos} = observer_cli_lib:get_pos(Page, Num, Pages, erlang:length(MQLenList)),
    FormatFunc =
        fun(Item, {Acc, Acc1, Pos}) ->
            {Pid, MQLen, CurFun, NameOrCall} = get_top_n_info(Item),
            {Reductions, Memory} = get_pid_info(Pid, [reductions, memory]),
            Format = get_message_queue_format(ChoosePos, Pos),
            R = io_lib:format(Format,
                [
                    Pos, pid_to_list(Pid),
                    observer_cli_lib:to_list(MQLen), NameOrCall,
                    observer_cli_lib:to_byte(Memory),
                    observer_cli_lib:to_list(Reductions), CurFun
                ]),
            {[R|Acc], [{Pos, Pid}|Acc1], Pos + 1}
        end,
    {Rows, PidList} = top_n_rows(FormatFunc, Start, lists:sublist(MQLenList, Start, Num)),
    {PidList, [Title | lists:reverse(Rows)]}.

top_n_rows(FormatFunc, Start, List) ->
    {Row, PidList, _} = lists:foldl(FormatFunc, {[], [], Start}, List),
    {Row, PidList}.

notify_pause_status() ->
    ?output("\e[31;1m PAUSE  INPUT (p, r/rr, b/bb, h/hh, m/mm) to resume or q to quit \e[0m~n").

get_memory_format(Pos, Pos) ->
    "|\e[42m~-3.3w|~-12.12s|~13.13s |~-38.38s|~21.21s| ~-9.9s|~-33.33s\e[49m|~n";
get_memory_format(_Pos, _RankPos) ->
    "|~-3.3w|~-12.12s|~13.13s |~-38.38s|~21.21s| ~-9.9s|~-33.33s|~n".

get_reduction_format(Pos, Pos) ->
    "|\e[42m~-3.3w|~-12.12s|~-21.21s|~-38.38s|~13.13s| ~-9.9s|~-34.34s\e[49m|~n";
get_reduction_format(_Pos, _RankPos) ->
    "|~-3.3w|~-12.12s|~-21.21s|~-38.38s|~13.13s| ~-9.9s|~-34.34s|~n".

get_message_queue_format(Pos, Pos) ->
    "|\e[42m~-3.3w|~-12.12s|~-11.11s|~-37.37s|~13.13s| ~-20.20s|~-34.34s\e[49m|~n";
get_message_queue_format(_Pos, _RankPos) ->
    "|~-3.3w|~-12.12s|~-11.11s|~-37.37s|~13.13s| ~-20.20s|~-34.34s|~n".

refresh_next_time(proc_count, Type, Interval) ->
    erlang:send_after(Interval, self(), {proc_count, Type});
refresh_next_time(proc_window, Type, _Interval) ->
    erlang:send_after(10, self(), {proc_window, Type}).

get_current_initial_call(Call) ->
    {_, CurFun} = lists:keyfind(current_function, 1, Call),
    {_, InitialCall} = lists:keyfind(initial_call, 1, Call),
    {observer_cli_lib:mfa_to_list(CurFun), InitialCall}.

get_port_proc_info(PortLimit, ProcLimit, ProcSum) ->
    ProcCount = proplists:get_value(process_count, ProcSum),
    PortCount = erlang:system_info(port_count),
    PortCountStr = integer_to_list(PortCount) ++ "/" ++ integer_to_list(PortLimit),
    ProcCountStr = integer_to_list(ProcCount) ++ "/" ++ integer_to_list(ProcLimit),
    PortWarning =
        case PortCount > PortLimit * ?COUNT_ALARM_THRESHOLD of
            true -> ?RED;
            false -> <<"">>
        end,
    ProcWarning =
        case ProcCount > ProcLimit * ?COUNT_ALARM_THRESHOLD of
            true -> ?RED;
            false -> <<"">>
        end,
    {PortWarning, ProcWarning, PortCountStr, ProcCountStr}.

format_atom_info(AtomLimit, AtomCount) ->
    Atom = integer_to_list(AtomCount) ++ "/" ++ integer_to_list(AtomLimit),
    case AtomCount > AtomLimit * ?COUNT_ALARM_THRESHOLD of
        true -> {?RED, Atom};
        false -> {<<"">>, Atom}
    end.

process_bar_format_style(Percent1, Percent2, IsLastLine) ->
    Warning1 =
        case Percent1 >= ?CPU_ALARM_THRESHOLD of
            true -> ?RED;
            false -> ?GREEN
        end,
    Warning2 =
        case Percent2 >= ?CPU_ALARM_THRESHOLD of
            true -> ?RED;
            false -> ?GREEN
        end,
    Format = <<"|", Warning1/binary, "|~2..0w ~-57.57s", "~s", Warning2/binary, " |~2..0w ~-57.57s", " ~s", " \e[0m|~n">>,
    case IsLastLine of
        true -> <<?UNDERLINE/binary, Format/binary>>;
        false -> Format
    end.

process_bar_format_style(Percent1, Percent2, Percent3, Percent4, IsLastLine) ->
    Warning1 =
        case Percent1 >= ?CPU_ALARM_THRESHOLD of
            true -> ?RED;
            false -> ?GREEN
        end,
    Warning2 =
        case Percent2 >= ?CPU_ALARM_THRESHOLD of
            true -> ?RED;
            false -> ?GREEN
        end,
    Warning3 =
        case Percent3 >= ?CPU_ALARM_THRESHOLD of
            true -> ?RED;
            false -> ?GREEN
        end,
    Warning4 =
        case Percent4 >= ?CPU_ALARM_THRESHOLD of
            true -> ?RED;
            false -> ?GREEN
        end,
    Format =
        <<"|",
            Warning1/binary, "|~-2.2w ~-22.22s", " ~s",
            Warning2/binary, " |~-2.2w ~-22.22s", " ~s",
            Warning3/binary, " |~-2.2w ~-22.22s", " ~s",
            Warning4/binary, " |~-2.2w ~-23.23s", " ~s",
            " \e[0m|~n">>,
    case IsLastLine of
        true -> <<?UNDERLINE/binary, Format/binary>>;
        false -> Format
    end.

get_top_n_info(Item) ->
    {Pid, Val, Call = [IsName | _]} = Item,
    {CurFun, InitialCall} = get_current_initial_call(Call),
    NameOrCall = display_name_or_initial_call(IsName, InitialCall, Pid),
    {Pid, Val, CurFun, NameOrCall}.

display_name_or_initial_call(IsName, _Call, _Pid) when is_atom(IsName) ->
    atom_to_list(IsName);
display_name_or_initial_call(_IsName, {proc_lib, init_p, 5}, Pid) ->
    observer_cli_lib:mfa_to_list(proc_lib:translate_initial_call(Pid)); %% translate gen_xxx behavior
display_name_or_initial_call(_IsName, Call, _Pid) ->
    observer_cli_lib:mfa_to_list(Call).

get_refresh_prompt(proc_count, Type, Interval, Rows) ->
    io_lib:format("recon:proc_count(~p, ~w) Interval:~wms", [Type, Rows, Interval]);
get_refresh_prompt(proc_window, Type, Interval, Rows) ->
    io_lib:format("recon:proc_window(~p, ~w, ~w) Interval:~wms", [Type, Rows, Interval, Interval]).

get_stable_system_info() ->
    [begin erlang:system_info(Item) end || Item <- ?STABLE_SYSTEM_KEY].

get_change_system_info() ->
    UsedMem = recon_alloc:memory(used),
    AllocatedMem = recon_alloc:memory(allocated),
    {UsedMem, AllocatedMem, AllocatedMem - UsedMem}.

get_atom_status() ->
    try erlang:system_info(atom_limit) of
        Limit ->
            Count = erlang:system_info(atom_count),
            {ok, Limit, Count}
    catch
        _:badarg -> {error, unsupported}
    end.

get_pid_info(Pid, Keys) ->
    case recon:info(Pid, Keys) of
        undefined -> {"die", "die"};
        [{_, Val1}, {_, Val2}] -> {Val1, Val2}
    end.

get_top_n(proc_window, Type, Interval, Rows, IsFirstTime)when not IsFirstTime ->
    recon:proc_window(Type, Rows, Interval);
get_top_n(_Func, Type, _Interval, Rows, _FirstTime) ->
    recon:proc_count(Type, Rows).

connect_error(Prompt, Node) ->
    Prop = <<?RED/binary, Prompt/binary, ?RESET/binary>>,
    ?output(Prop, [Node]).

start_process_view(StorePid, RenderPid, Opts = #view_opts{home = Home}, LastSchWallFlag, AutoJump) ->
    #home{cur_page = CurPage, pages = Pages} = Home,
    {_, CurPos} = lists:keyfind(CurPage, 1, Pages),
    case observer_cli_store:lookup_pos(StorePid, CurPos) of
        {CurPos, ChoosePid} ->
            observer_cli_lib:exit_processes([StorePid, RenderPid]),
            erlang:system_flag(scheduler_wall_time, LastSchWallFlag),
            observer_cli_process:start(ChoosePid, Opts);
        {_, ChoosePid} when AutoJump ->
            observer_cli_lib:exit_processes([StorePid, RenderPid]),
            erlang:system_flag(scheduler_wall_time, LastSchWallFlag),
            observer_cli_process:start(ChoosePid, Opts);
        _ -> manager(StorePid, RenderPid, Opts, LastSchWallFlag)
    end.

check_auto_row() ->
    case io:rows() of
        {ok, _} -> true;
        {error, _} -> false
    end.

node_stats({LastIn, LastOut, LastGCs, LastWords, LastScheduleWall}) ->
    ProcC = erlang:system_info(process_count),
    RunQ = erlang:statistics(run_queue),
    %% Mem (Absolutes)
    Mem = erlang:memory(),
    Tot = proplists:get_value(total, Mem),
    ProcM = proplists:get_value(processes_used, Mem),
    Atom = proplists:get_value(atom_used, Mem),
    Bin = proplists:get_value(binary, Mem),
    Ets = proplists:get_value(ets, Mem),
    %% Incremental
    New = {In, Out, GCs, Words, ScheduleWall} = get_incremental_stats(),
    BytesIn = In-LastIn,
    BytesOut = Out-LastOut,
    GCCount = GCs-LastGCs,
    GCWords = Words-LastWords,
    {_, Reds} = erlang:statistics(reductions),
    ScheduleUsage = recon_lib:scheduler_usage_diff(LastScheduleWall, ScheduleWall),
    {
        {[
            {process_count, ProcC}, {run_queue, RunQ},
            {memory_total, Tot},
            {memory_procs, ProcM}, {memory_atoms, Atom},
            {memory_bin, Bin}, {memory_ets, Ets}],
            [
                {bytes_in, BytesIn}, {bytes_out, BytesOut},
                {gc_count, GCCount}, {gc_words_reclaimed, GCWords},
                {reductions, Reds}, {scheduler_usage, ScheduleUsage}
            ]
        },
        New
    }.

get_incremental_stats() ->
    {{input, In}, {output, Out}} = erlang:statistics(io),
    {GCs, Words, _} = erlang:statistics(garbage_collection),
    ScheduleWall = erlang:statistics(scheduler_wall_time),
    {In, Out, GCs, Words, ScheduleWall}.
