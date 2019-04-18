%% -------------------------------------------------------------------
%%
%% riak_kv_ttaefs_manager: coordination of full-sync replication
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc coordination of full-sync replication

-module(riak_kv_ttaaefs_manager).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-behaviour(gen_server).

-export([init/1,
        handle_call/3,
        handle_cast/2,
        handle_info/2,
        terminate/2,
        code_change/3]).

-export([start_link/0,
            pause/1,
            resume/1,
            set_sink/4,
            set_source/4,
            set_allsync/3,
            set_bucketsync/2,
            process_workitem/4]).

-define(SLICE_COUNT, 100).
-define(SECONDS_IN_DAY, 86400).
-define(INITIAL_TIMEOUT, 60000).
    % Wait a minute before the first allocation is considered,  Lot may be
    % going on at a node immeidately at startup
-define(LOOP_TIMEOUT, 15000).
    % Always wait at least 15s after completing an action before
    % prompting another
-define(CRASH_TIMEOUT, 3600 * 1000).
    % Assume that an exchange has crashed if not response received in this
    % interval, to allow exchanges to be re-scheduled.

-record(state, {slice_allocations = [] :: list(allocation()),
                slice_set_start = os:timestamp() :: erlang:timestamp(),
                schedule :: schedule_wants(),
                backup_schedule :: schedule_wants(),
                peer_ip :: string(),
                peer_port :: integer(),
                peer_protocol :: http|pb,
                local_ip :: string(),
                local_port :: integer(),
                local_protocol :: http|pb,
                scope :: bucket|all|disabled,
                bucket_list :: list()|undefined,
                local_nval :: pos_integer()|undefined,
                remote_nval :: pos_integer()|undefined,
                queue_name :: riak_kv_replrtq_src:queue_name(),
                slot_info_fun :: fun(),
                slice_count = ?SLICE_COUNT :: pos_integer(),
                is_paused = false :: boolean()
                }).

-type client_protocol() :: http.
-type client_ip() :: string().
-type client_port() :: pos_integer().
-type nval() :: pos_integer()|range. % Range queries do not have an n-val
-type work_item() :: no_sync|all_sync|day_sync|hour_sync.
-type schedule_want() :: {work_item(), non_neg_integer()}.
-type slice() :: pos_integer().
-type allocation() :: {slice(), work_item()}.
-type schedule_wants() :: [schedule_want()].
-type node_info() :: {pos_integer(), pos_integer()}. % Node and node count
-type ttaaefs_state() :: #state{}.


-export_type([work_item/0]).

%%%============================================================================
%%% API
%%%============================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
    
%% @doc
%% Override shcedule and process an individual work_item.  If called from
%% riak_client an integer ReqID is passed to allow for a response to be
%% returned.  If using directly from riak attach use no_reply as the request
%% ID.  The fourth element of the input should be an erlang timestamp
%% representing now - but may be altered to something in the past or future in
%% tests.
-spec process_workitem(pid()|atom(), work_item(), no_reply|integer(),
                                                    erlang:timestamp()) -> ok.
process_workitem(Pid, WorkItem, ReqID, Now) ->
    gen_server:cast(Pid, {WorkItem, ReqID, self(), Now}).

-spec pause(pid()|atom()) -> ok|{error, already_paused}.
pause(Pid) ->
    gen_server:call(Pid, pause).

-spec resume(pid()|atom()) -> ok|{error, not_paused}.
resume(Pid) ->
    gen_server:call(Pid, resume).

-spec set_sink(pid()|atom(), http, string(), integer()) -> ok.
set_sink(Pid, Protocol, IP, Port) ->
    gen_server:call(Pid, {set_sink, Protocol, IP, Port}).

-spec set_source(pid()|atom(), http, string(), integer()) -> ok.
set_source(Pid, Protocol, IP, Port) ->
    gen_server:call(Pid, {set_source, Protocol, IP, Port}).

%% @doc
%% Set the manager to do full sync (e.g. using cached trees).  This will leave
%% automated sync disabled.  To re-enable the sync use resume/1
-spec set_allsync(pid()|atom(), pos_integer(), pos_integer()) -> ok.
set_allsync(Pid, LocalNVal, RemoteNVal) ->
    gen_server:call(Pid, {set_allsync, LocalNVal, RemoteNVal}).

%% @doc
%% Set the manager to sync or a list of buckets.  This will leave
%% automated sync disabled.  To re-enable the sync use resume/1
-spec set_bucketsync(pid()|atom, list(riak_object:bucket())) -> ok.
set_bucketsync(Pid, BucketList) ->
    gen_server:call(Pid, {set_bucketsync, BucketList}).


%%%============================================================================
%%% gen_server callbacks
%%%============================================================================

init([]) ->
    State0 = #state{},
    % Get basic coniguration of scope (either all keys for each n_val, or a
    % specific list of buckets)
    Scope = app_helper:get_env(riak_kv, ttaaefs_scope, disabled),

    State1 = 
        case Scope of
            all ->
                LocalNVal = app_helper:get_env(riak_kv, ttaaefs_localnval),
                RemoteNVal = app_helper:get_env(riak_kv, ttaaefs_remotenval),
                State0#state{scope=all,
                                local_nval = LocalNVal,
                                remote_nval = RemoteNVal};
            bucket ->
                Bucket = app_helper:get_env(riak_kv, ttaaefs_bucket),
                Type = app_helper:get_env(riak_kv, ttaaefs_buckettype),
                BucketT = {list_to_binary(Type), list_to_binary(Bucket)},
                State0#state{scope=bucket, bucket_list=[BucketT]};
            disabled ->
                State0#state{scope = disabled}
        end,
    NoCheck = app_helper:get_env(riak_kv, ttaaefs_nocheck),
    AllCheck = app_helper:get_env(riak_kv, ttaaefs_allcheck),
    HourCheck = app_helper:get_env(riak_kv, ttaaefs_hourcheck),
    DayCheck = app_helper:get_env(riak_kv, ttaaefs_daycheck),

    {SliceCount, Schedule} = 
        case Scope of
            all ->
                {NoCheck + AllCheck,
                    [{no_sync, NoCheck}, {all_sync, AllCheck},
                        {day_sync, 0}, {hour_sync, 0}]};
            bucket ->
                {NoCheck + AllCheck + HourCheck + DayCheck,
                    [{no_sync, NoCheck}, {all_sync, AllCheck},
                        {day_sync, DayCheck}, {hour_sync, HourCheck}]};
            disabled ->
                {24, [{no_sync, 24}, {all_sync, 0}, 
                        {day_sync, 0}, {hour_sync, 0}]}
                    % No sync once an hour if disabled
        end,
    State2 = State1#state{schedule = Schedule,
                            slice_count = SliceCount,
                            slot_info_fun = fun get_slotinfo/0},
    
    % Fetch connectivity information for remote cluster
    PeerIP = app_helper:get_env(riak_kv, ttaaefs_peerip),
    PeerPort = app_helper:get_env(riak_kv, ttaaefs_peerport),
    PeerProtocol = app_helper:get_env(riak_kv, ttaaefs_peerprotocol),
    % Fetch connectivity information for local cluster
    LocalIP = app_helper:get_env(riak_kv, ttaaefs_localip),
    LocalPort = app_helper:get_env(riak_kv, ttaaefs_localport),
    LocalProtocol = app_helper:get_env(riak_kv, ttaaefs_localprotocol),

    % Queue name to be used for AAE exchanges on this cluster
    SrcQueueName = app_helper:get_env(riak_kv, ttaaefs_queuename),

    State3 = 
        State2#state{peer_ip = PeerIP,
                        peer_port = PeerPort,
                        peer_protocol = PeerProtocol,
                        local_ip = LocalIP,
                        local_port = LocalPort,
                        local_protocol = LocalProtocol,
                        queue_name = SrcQueueName},
    
    lager:info("Initiated Tictac AAE Full-Sync Mgr with scope=~w", [Scope]),
    {ok, State3, ?INITIAL_TIMEOUT}.

handle_call(pause, _From, State) ->
    case State#state.is_paused of
        true ->
            {reply, {error, already_paused}, State};
        false -> 
            PausedSchedule =
                [{no_sync, State#state.slice_count}, {all_sync, 0},
                    {day_sync, 0}, {hour_sync, 0}],
            BackupSchedule = State#state.schedule,
            {reply, ok, State#state{schedule = PausedSchedule,
                                    backup_schedule = BackupSchedule,
                                    is_paused = true}}
    end;
handle_call(resume, _From, State) ->
    case State#state.is_paused of
        true ->
            Schedule = State#state.backup_schedule,
            {reply,
                ok,
                State#state{schedule = Schedule, is_paused = false},
                ?INITIAL_TIMEOUT};
        false ->
            {reply, {error, not_paused}, State, ?INITIAL_TIMEOUT}
    end;
handle_call({set_sink, Protocol, PeerIP, PeerPort}, _From, State) ->
    State0 = 
        State#state{peer_ip = PeerIP,
                        peer_port = PeerPort,
                        peer_protocol = Protocol},
    {reply, ok, State0, ?INITIAL_TIMEOUT};
handle_call({set_source, Protocol, PeerIP, PeerPort}, _From, State) ->
    State0 = 
        State#state{local_ip = PeerIP,
                        local_port = PeerPort,
                        local_protocol = Protocol},
    {reply, ok, State0, ?INITIAL_TIMEOUT};
handle_call({set_allsync, LocalNVal, RemoteNVal}, _From, State) ->
    {reply,
        ok,
        State#state{scope = all,
                    local_nval = LocalNVal,
                    remote_nval = RemoteNVal}};
handle_call({set_bucketsync, BucketList}, _From, State) ->
    {reply,
        ok,
        State#state{scope = bucket,
                    bucket_list = BucketList}}.

handle_cast({reply_complete, _ReqID, _Result}, State) ->
    % Add a stat update in here
    {noreply, State, ?LOOP_TIMEOUT};
handle_cast({no_sync, ReqID, From}, State) ->
    case ReqID of
        no_reply ->
            ok;
        _ ->
            From ! {ReqID, {no_sync, 0}}
    end,
    {noreply, State, ?LOOP_TIMEOUT};
handle_cast({all_sync, ReqID, From, _Now}, State) ->
    {LNVal, RNVal, Filter, NextBucketList, Ref} =
        case State#state.scope of
            all ->
                {State#state.local_nval, State#state.remote_nval,
                    none, undefined, full};
            bucket ->
                [H|T] = State#state.bucket_list,
                {range, range, 
                    {filter, H, all, large, all, all, pre_hash},
                    T ++ [H],
                    partial}
        end,
    {State0, Timeout} =
        sync_clusters(From, ReqID, LNVal, RNVal, Filter,
                        NextBucketList, Ref, State),
    {noreply, State0, Timeout};
handle_cast({hour_sync, ReqID, From, Now}, State) ->
    case State#state.scope of
        all ->
            lager:warning("Invalid work_item=hour_sync for Scope=all"),
            {noreply, State, ?INITIAL_TIMEOUT};
        bucket ->
            [H|T] = State#state.bucket_list,
            {MegaSecs, Secs, _MicroSecs} = Now,
            UpperTime = MegaSecs * 1000000  + Secs,
            LowerTime = UpperTime - 60 * 60,
            % Note that the tree size is amended as well as the time range.
            % The bigger the time range, the bigger the tree.  Bigger trees
            % are less efficient when there is little change, but can more
            % accurately reflect bigger changes (with less fasle positives).
            Filter =
                {filter, H, all, small, all,
                {LowerTime, UpperTime}, pre_hash},
            NextBucketList = T ++ [H],
            {State0, Timeout} =
                sync_clusters(From, ReqID, range, range, Filter,
                                NextBucketList, partial, State),
            {noreply, State0, Timeout}
    end;
handle_cast({day_sync, ReqID, From, Now}, State) ->
    case State#state.scope of
        all ->
            lager:warning("Invalid work_item=day_sync for Scope=all"),
            {noreply, State, ?INITIAL_TIMEOUT};
        bucket ->
            [H|T] = State#state.bucket_list,
            {MegaSecs, Secs, _MicroSecs} = Now,
            UpperTime = MegaSecs * 1000000  + Secs,
            LowerTime = UpperTime - 60 * 60 * 24,
            % Note that the tree size is amended as well as the time range.
            % The bigger the time range, the bigger the tree.  Bigger trees
            % are less efficient when there is little change, but can more
            % accurately reflect bigger changes (with less fasle positives).
            Filter =
                {filter, H, all, medium, all,
                {LowerTime, UpperTime}, pre_hash},
            NextBucketList = T ++ [H],
            {State0, Timeout} =
                sync_clusters(From, ReqID, range, range, Filter,
                                NextBucketList, partial, State),
            {noreply, State0, Timeout}
    end.

handle_info(timeout, State) ->
    SlotInfoFun = State#state.slot_info_fun,
    {WorkItem, Wait, RemainingSlices, ScheduleStartTime} = 
        take_next_workitem(State#state.slice_allocations,
                            State#state.schedule,
                            State#state.slice_set_start,
                            SlotInfoFun(),
                            State#state.slice_count),
    erlang:send_after(Wait * 1000, self(), {work_item, WorkItem}),
    {noreply, State#state{slice_allocations = RemainingSlices,
                            slice_set_start = ScheduleStartTime}};
handle_info({work_item, WorkItem}, State) ->
    process_workitem(self(), WorkItem, no_reply, os:timestamp()),
    {noreply, State}.

terminate(normal, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.


%%%============================================================================
%%% Internal functions
%%%============================================================================


%% @doc
%% Sync two clusters - return an updated loop state and a timeout
-spec sync_clusters(pid(), integer()|no_reply,
                nval(), nval(), tuple(), list(), full|partial,
                ttaaefs_state()) -> {ttaaefs_state(), pos_integer()}.
sync_clusters(From, ReqID, LNVal, RNVal, Filter, NextBucketList, Ref, State) ->
    RemoteClient =
        init_client(State#state.peer_protocol,
                    State#state.peer_ip,
                    State#state.peer_port),
    LocalClient =
        init_client(State#state.local_protocol,
                    State#state.local_ip,
                    State#state.local_port),

    case RemoteClient of
        no_client ->
            {State#state{bucket_list = NextBucketList},
                ?LOOP_TIMEOUT};
        _ ->
            RemoteSendFun = generate_sendfun(RemoteClient, RNVal),
            LocalSendFun = generate_sendfun(LocalClient, LNVal),
            ReplyFun = generate_replyfun(ReqID, From),
            ReqID0 = 
                case ReqID of
                    no_reply ->
                        erlang:phash2({self(), os:timestamp()});
                    _ ->
                        ReqID
                end,
            RepairFun = generate_repairfun(ReqID0, State#state.queue_name),
            
            {ok, ExPid, ExID} =
                aae_exchange:start(Ref,
                                    [{LocalSendFun, all}],
                                    [{RemoteSendFun, all}],
                                    RepairFun,
                                    ReplyFun,
                                    Filter, []),
            
            lager:info("Starting full-sync ReqID=~w id=~s pid=~w",
                            [ReqID0, ExID, ExPid]),
            
            {State#state{bucket_list = NextBucketList},
                ?CRASH_TIMEOUT}
    end.


%% @doc
%% Check the slot info - how many nodes are there active in the cluster, and
%% which is the slot for this node in the cluster.
%% An alternative slot_info function may be passed in when initialising the
%% server (e.g. for test)
-spec get_slotinfo() -> node_info().
get_slotinfo() ->
    UpNodes = lists:sort(riak_core_node_watcher:nodes(riak_kv)),
    NotMe = lists:takewhile(fun(N) -> N /= node() end, UpNodes),
    {length(NotMe) + 1, length(UpNodes)}.

%% @doc
%% Return a function which will send aae_exchange messages to a remote
%% cluster, and return the response.  The function should make an async call
%% to try and make the remote and local cluster sends happen as close to
%% parallel as possible. 
-spec generate_sendfun(rhc:rhc(), nval()) -> fun().
generate_sendfun(RHC, NVal) ->
    fun(Msg, all, Colour) ->
        AAE_Exchange = self(),
        ReturnFun = 
            fun(R) -> 
                aae_exchange:reply(AAE_Exchange, R, Colour)
            end,
        SendFun = remote_sender(Msg, RHC, ReturnFun, NVal),
        _SpawnedPid = spawn(SendFun),
        ok
    end.

%% @doc
%% Make a remote client for connecting to the remote cluster
-spec init_client(client_protocol(), client_ip(), client_port())
                                                        -> rhc:rhc()|no_client.
init_client(http, IP, Port) ->
    RHC = rhc:create(IP, Port, "riak", []),
    case rhc:ping(RHC) of
        ok ->
            RHC;
        {error, Error} ->
            lager:warning("Cannot reach remote cluster ~p ~p with error ~p",
                            [IP, Port, Error]),
            no_client
    end.

%% @doc
%% Translate aae_Exchange messages into riak erlang http client requests
-spec remote_sender(any(), rhc:rhc(), fun(), nval()) -> fun().
remote_sender(fetch_root, RHC, ReturnFun, NVal) ->
    fun() ->
        {ok, {root, Root}}
            = rhc:aae_merge_root(RHC, NVal),
        ReturnFun(Root)
    end;
remote_sender({fetch_branches, BranchIDs}, RHC, ReturnFun, NVal) ->
    fun() ->
        {ok, {branches, ListOfBranchResults}}
            = rhc:aae_merge_branches(RHC, NVal, BranchIDs),
        ReturnFun(ListOfBranchResults)
    end;
remote_sender({fetch_clocks, SegmentIDs}, RHC, ReturnFun, NVal) ->
    fun() ->
        case rhc:aae_fetch_clocks(RHC, NVal, SegmentIDs) of
            {ok, {keysclocks, KeysClocks}} ->
                ReturnFun(lists:map(fun({{B, K}, VC}) -> {B, K, VC} end,
                            KeysClocks));
            {error, Error} ->
                lager:warning("Error of ~w in fetch_clocks response",
                                [Error]),
                ReturnFun({error, Error})
        end
    end;
remote_sender({merge_tree_range, B, KR, TS, SF, MR, HM},
                    RHC, ReturnFun, range) ->
    SF0 = format_segment_filter(SF),
    fun() ->
        {ok, {tree, Tree}}
            = rhc:aae_range_tree(RHC, B, KR, TS, SF0, MR, HM),
        ReturnFun(leveled_tictac:import_tree(Tree))
    end;
remote_sender({fetch_clocks_range, B0, KR, SF, MR}, RHC, ReturnFun, range) ->
    SF0 = format_segment_filter(SF),
    fun() ->
        {ok, {keysclocks, KeysClocks}}
            = rhc:aae_range_clocks(RHC, B0, KR, SF0, MR),
        ReturnFun(lists:map(fun({{B, K}, VC}) -> {B, K, VC} end, KeysClocks))
    end.

%% @doc
%% The segment filter as produced by aae_exchange has a different format to
%% thann the one expected by the riak http erlang client - so that conflict
%% is resolved here
format_segment_filter(all) ->
    all;
format_segment_filter({segments, SegList, TreeSize}) ->
    {SegList, TreeSize}.

%% @doc
%% Generate a reply fun (as there is nothing to reply to this will simply
%% update the stats for Tictac AAE full-syncs
-spec generate_replyfun(integer()|no_reply, pid()) -> fun().
generate_replyfun(ReqID, From) ->
    Pid = self(),
    fun(Result) ->
        case ReqID of
            no_reply ->
                ok;
            _ ->
                % Reply to riak_client
                From ! {ReqID, Result}
        end,
        gen_server:cast(Pid, {reply_complete, ReqID, Result})
    end.

%% @doc
%% Generate a repair fun which will compare clocks between source and sink
%% cluster, and prompt the re-replication of objects that are more up-to-date
%% in the local (source) cluster
%%
%% The RepairFun will receieve a list of tuples of:
%% - Bucket
%% - Key
%% - Source-Side VC
%% - Sink-Side VC
%%
%% If the sink side dominates the repair should log and not repair, otherwise
%% the object should be repaired by requeueing.  Requeueing will cause the
%% object to be re-replicated to all destination clusters (not just a specific
%% sink cluster)
-spec generate_repairfun(integer(), riak_kv_replrtq_src:queue_name()) -> fun().
generate_repairfun(ExchangeID, QueueName) ->
    fun(RepairList) ->
        lager:info("Repair to list of length ~w", [length(RepairList)]),
        FoldFun =
            fun({{B, K}, {SrcVC, SinkVC}}, {SourceL, SinkC}) ->
                % how are the vector clocks encoded at this point?
                % The erlify_aae_keyclock will have base64 decoded the clock
                case vclock_dominates(SinkVC, SrcVC) of
                    true ->
                        {SourceL, SinkC + 1};
                    false ->
                        {[{B, K, SrcVC, to_fetch}|SourceL], SinkC}
                end
            end,
        {ToRepair, SinkDCount} = lists:foldl(FoldFun, {[], 0}, RepairList),
        lager:info("AAE exchange ~w shows sink ahead for ~w keys", 
                    [ExchangeID, SinkDCount]),
        lager:info("AAE exchange ~w outputs ~w keys to be repaired",
                    [ExchangeID, length(ToRepair)]),
        riak_kv_replrtq_src:replrtq_ttaefs(repl_kv_replrtq_src,
                                            QueueName,
                                            ToRepair),
        lager:info("AAE exchange ~w has requeue complete for ~w keys",
                    [ExchangeID, length(ToRepair)])
    end.


vclock_dominates(none, _SrcVC)  ->
    false;
vclock_dominates(_SinkVC, none) ->
    true;
vclock_dominates(SinkVC, SrcVC) ->
    vclock:dominates(riak_object:decode_vclock(SinkVC),
                        riak_object:decode_vclock(SrcVC)).


%% @doc
%% Take the next work item from the list of allocations, assuming that the
%% starting time for that work item has not alreasy passed.  If there are no
%% more items queue, start a new queue based on the wants for the schedule.
-spec take_next_workitem(list(allocation()), 
                            schedule_wants(),
                            erlang:timestamp(),
                            node_info(),
                            pos_integer()) ->
                                {work_item(), pos_integer(),
                                    list(allocation()), erlang:timestamp()}.
take_next_workitem([], Wants, ScheduleStartTime, SlotInfo, SliceCount) ->
    NewAllocations = choose_schedule(Wants),
    % Should be 24 hours after ScheduleStartTime - so add 24 hours to
    % ScheduleStartTime
    {Mega, Sec, _Micro} = ScheduleStartTime,
    Seconds = Mega * 1000 + Sec + 86400,
    RevisedStartTime = {Seconds div 1000, Seconds rem 1000, 0},
    take_next_workitem(NewAllocations, Wants,
                        RevisedStartTime, SlotInfo, SliceCount);
take_next_workitem([NextAlloc|T], Wants,
                        ScheduleStartTime, SlotInfo, SliceCount) ->
    {NodeNumber, NodeCount} = SlotInfo,
    SliceSeconds = ?SECONDS_IN_DAY div SliceCount,
    SlotSeconds = (NodeNumber - 1) * (SliceSeconds div NodeCount),
    {SliceNumber, NextAction} = NextAlloc,
    {Mega, Sec, _Micro} = ScheduleStartTime,
    ScheduleSeconds = 
        Mega * 1000 + Sec + SlotSeconds + SliceNumber * SliceSeconds,
    {MegaNow, SecNow, _MicroNow} = os:timestamp(),
    NowSeconds = MegaNow * 1000 + SecNow,
    case ScheduleSeconds > NowSeconds of
        true ->
            {NextAction, ScheduleSeconds - NowSeconds, T, ScheduleStartTime};
        false ->
            lager:info("Tictac AAE skipping action ~w as manager running"
                        ++ "~w seconds late",
                        [NextAction, NowSeconds - ScheduleSeconds]),
            take_next_workitem(T, Wants,
                                ScheduleStartTime, SlotInfo, SliceCount)
    end.


%% @doc
%% Calculate an allocation of activity for the next 24 hours based on the
%% configured schedule-needs.
-spec choose_schedule(schedule_wants()) -> list(allocation()).
choose_schedule(ScheduleWants) ->
    [{no_sync, NoSync}, {all_sync, AllSync},
        {day_sync, DaySync}, {hour_sync, HourSync}] = ScheduleWants,
    SliceCount = NoSync + AllSync + DaySync + HourSync,
    Slices = lists:seq(1, SliceCount),
    Allocations = [],
    lists:sort(choose_schedule(Slices,
                                Allocations,
                                {NoSync, AllSync, DaySync, HourSync})).

choose_schedule([], Allocations, {0, 0, 0, 0}) ->
    lists:ukeysort(1, Allocations);
choose_schedule(Slices, Allocations, {NoSync, 0, 0, 0}) ->
    {HL, [Allocation|TL]} =
        lists:split(random:uniform(length(Slices)) - 1, Slices),
    choose_schedule(HL ++ TL,
                    [{Allocation, no_sync}|Allocations],
                    {NoSync - 1, 0, 0, 0});
choose_schedule(Slices, Allocations, {NoSync, AllSync, 0, 0}) ->
    {HL, [Allocation|TL]} =
        lists:split(random:uniform(length(Slices)) - 1, Slices),
    choose_schedule(HL ++ TL,
                    [{Allocation, all_sync}|Allocations],
                    {NoSync, AllSync - 1, 0, 0});
choose_schedule(Slices, Allocations, {NoSync, AllSync, DaySync, 0}) ->
    {HL, [Allocation|TL]} =
        lists:split(random:uniform(length(Slices)) - 1, Slices),
    choose_schedule(HL ++ TL,
                    [{Allocation, day_sync}|Allocations],
                    {NoSync, AllSync, DaySync - 1, 0});
choose_schedule(Slices, Allocations, {NoSync, AllSync, DaySync, HourSync}) ->
    {HL, [Allocation|TL]} =
        lists:split(random:uniform(length(Slices)) - 1, Slices),
    choose_schedule(HL ++ TL,
                    [{Allocation, hour_sync}|Allocations],
                    {NoSync, AllSync, DaySync, HourSync - 1}).


%%%============================================================================
%%% Test
%%%============================================================================

-ifdef(TEST).

choose_schedule_test() ->
    NoSyncAllSchedule =
        [{no_sync, 100}, {all_sync, 0}, {day_sync, 0}, {hour_sync, 0}],
    NoSyncAll = choose_schedule(NoSyncAllSchedule),
    ExpNoSyncAll = lists:map(fun(I) -> {I, no_sync} end, lists:seq(1, 100)),
    ?assertMatch(NoSyncAll, ExpNoSyncAll),

    AllSyncAllSchedule =
        [{no_sync, 0}, {all_sync, 100}, {day_sync, 0}, {hour_sync, 0}],
    AllSyncAll = choose_schedule(AllSyncAllSchedule),
    ExpAllSyncAll = lists:map(fun(I) -> {I, all_sync} end, lists:seq(1, 100)),
    ?assertMatch(AllSyncAll, ExpAllSyncAll),
    
    MixedSyncSchedule = 
        [{no_sync, 0}, {all_sync, 1}, {day_sync, 4}, {hour_sync, 95}],
    MixedSync = choose_schedule(MixedSyncSchedule),
    ?assertMatch(100, length(MixedSync)),
    IsSyncFun = fun({_I, Type}) -> Type == hour_sync end,
    SliceForHourFun = fun({I, hour_sync}) -> I end,
    HourWorkload =
        lists:map(SliceForHourFun, lists:filter(IsSyncFun, MixedSync)),
    ?assertMatch(95, length(lists:usort(HourWorkload))),
    FoldFun = 
        fun(I, Acc) ->
            true = I > Acc,
            I
        end,
    BiggestI = lists:foldl(FoldFun, 0, HourWorkload),
    ?assertMatch(true, BiggestI >= 95).

take_first_workitem_test() ->
    Wants = [{no_sync, 100}, {all_sync, 0}, {day_sync, 0}, {hour_sync, 0}],
    {Mega, Sec, Micro} = os:timestamp(),
    TwentyFourHoursAgo = Mega * 1000 + Sec - (60 * 60 * 24),
    {NextAction, PromptSeconds, _T, ScheduleStartTime} = 
        take_next_workitem([], Wants,
                            {TwentyFourHoursAgo div 1000,
                                TwentyFourHoursAgo rem 1000, Micro},
                            {1, 8},
                            100),
    ?assertMatch(no_sync, NextAction),
    ?assertMatch(true, ScheduleStartTime > {Mega, Sec, Micro}),
    ?assertMatch(true, PromptSeconds > 0),
    {NextAction, PromptMoreSeconds, _T, ScheduleStartTime} = 
        take_next_workitem([], Wants,
                            {TwentyFourHoursAgo div 1000,
                                TwentyFourHoursAgo rem 1000, Micro},
                            {2, 8},
                            100),
    ?assertMatch(true, PromptMoreSeconds > PromptSeconds),
    {NextAction, PromptEvenMoreSeconds, T, ScheduleStartTime} = 
        take_next_workitem([], Wants,
                            {TwentyFourHoursAgo div 1000,
                                TwentyFourHoursAgo rem 1000, Micro},
                            {7, 8},
                            100),
    ?assertMatch(true, PromptEvenMoreSeconds > PromptMoreSeconds),
    {NextAction, PromptYetMoreSeconds, _T0, ScheduleStartTime} = 
        take_next_workitem(T, Wants, ScheduleStartTime, {1, 8}, 100),
    ?assertMatch(true, PromptYetMoreSeconds > PromptEvenMoreSeconds).



-endif.
