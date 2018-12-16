%% -------------------------------------------------------------------
%%
%% Copyright (c) 2018 Christopher S. Meiklejohn.  All Rights Reserved.
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

-module(partisan_trace_orchestrator).
-author("Christopher Meiklejohn <christopher.meiklejohn@gmail.com>").

-behaviour(gen_server).

-include("partisan.hrl").

%% API
-export([start_link/0,
         start_link/1,
         trace/2,
         replay/2,
         reset/0,
         identify/1,
         print/0]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {previous_trace=[],
                trace=[], 
                replay=false,
                blocked_processes=[],
                identifier=undefined}).

-define(FILENAME, "/tmp/partisan.trace").

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Same as start_link([]).
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    start_link([]).

%% @doc Start and link to calling process.
-spec start_link(list())-> {ok, pid()} | ignore | {error, term()}.
start_link(Opts) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, Opts, []).

%% @doc Record trace message.
trace(Type, Message) ->
    gen_server:call(?MODULE, {trace, Type, Message}, infinity).

%% @doc Replay trace.
replay(Type, Message) ->
    gen_server:call(?MODULE, {replay, Type, Message}, infinity).

%% @doc Reset trace.
reset() ->
    gen_server:call(?MODULE, reset, infinity).

%% @doc Print trace.
print() ->
    gen_server:call(?MODULE, print, infinity).

%% @doc Identify trace.
identify(Identifier) ->
    gen_server:call(?MODULE, {identify, Identifier}, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% @private
-spec init([]) -> {ok, #state{}}.
init([]) ->
    lager:info("Test orchestrator started on node: ~p", [node()]),

    case os:getenv("REPLAY") of 
        false ->
            %% This is not a replay, so store the current trace.
            lager:info("~p: recording trace to file.", [?MODULE]),
            {ok, #state{trace=[], blocked_processes=[]}};
        _ ->
            %% This is a replay, so load the previous trace.
            lager:info("~p: loading previous trace for replay.", [?MODULE]),

            {ok, Bin} = file:read_file(?FILENAME),
            Lines = binary_to_term(Bin),

            lists:foreach(fun(Line) ->
                lager:info("~p: ~p", [?MODULE, Line])
            end, Lines),

            lager:info("~p: trace loaded.", [?MODULE]),

            {ok, #state{previous_trace=Lines, replay=true, blocked_processes=[]}}
    end.

%% @private
-spec handle_call(term(), {pid(), term()}, #state{}) ->
    {reply, term(), #state{}}.
handle_call({trace, Type, Message}, _From, #state{trace=Trace0}=State) ->
    %% lager:info("~p: recording trace type: ~p message: ~p", [?MODULE, Type, Message]),
    {reply, ok, State#state{trace=Trace0++[{Type, Message}]}};
handle_call({replay, Type, Message}, From, #state{previous_trace=PreviousTrace0, replay=Replay, blocked_processes=BlockedProcesses0}=State) ->
    case Replay of 
        true ->
            %% Find next message that should arrive based on the trace.
            %% Can we process immediately?
            case can_deliver_based_on_trace({Type, Message}, PreviousTrace0) of 
                true ->
                    %% Deliver as much as we can.
                    {PreviousTrace, BlockedProcesses} = trace_deliver(PreviousTrace0, BlockedProcesses0),

                    %% Record new trace position and new list of blocked processes.
                    {reply, ok, State#state{blocked_processes=BlockedProcesses, previous_trace=PreviousTrace}};
                false ->
                    %% If not, store message, block caller until processed.
                    BlockedProcesses = [{{Type, Message}, From} | BlockedProcesses0],

                    %% Block the process.
                    {noreply, State#state{blocked_processes=BlockedProcesses}}
            end;
        false ->
            {reply, ok, State}
    end;
handle_call(reset, _From, State) ->
    lager:info("~p: resetting trace.", [?MODULE]),
    {reply, ok, State#state{trace=[], identifier=undefined}};
handle_call({identify, Identifier}, _From, State) ->
    lager:info("~p: identifying trace: ~p", [?MODULE, Identifier]),
    {reply, ok, State#state{identifier=Identifier}};
handle_call(print, _From, #state{trace=Trace, replay=Replay}=State) ->
    lager:info("~p: printing trace", [?MODULE]),

    lists:foldl(fun({Type, Message}, Count) ->
        case Type of
            pre_interposition_fun ->
                ok;
            interposition_fun ->
                %% Destructure message.
                {TracingNode, OriginNode, InterpositionType, MessagePayload} = Message,

                %% Format trace accordingly.
                case InterpositionType of
                    receive_message ->
                        lager:info("~p: ~p: ~p <- ~p: ~p", [?MODULE, Count, TracingNode, OriginNode, MessagePayload]);
                    forward_message ->
                        lager:info("~p: ~p: ~p => ~p: ~p", [?MODULE, Count, TracingNode, OriginNode, MessagePayload])
                end;
            post_interposition_fun ->
                %% Destructure message.
                {TracingNode, OriginNode, InterpositionType, MessagePayload, RewrittenMessagePayload} = Message,

                %% Format trace accordingly.
                case MessagePayload =:= RewrittenMessagePayload of 
                    true ->
                        case InterpositionType of
                            receive_message ->
                                lager:info("~p: ~p: ~p <- ~p: ~p", [?MODULE, Count, TracingNode, OriginNode, MessagePayload]);
                            forward_message ->
                                lager:info("~p: ~p: ~p => ~p: ~p", [?MODULE, Count, TracingNode, OriginNode, MessagePayload])
                        end;
                    false ->
                        case RewrittenMessagePayload of 
                            undefined ->
                                case InterpositionType of
                                    receive_message ->
                                        lager:info("~p: ~p: ~p <- ~p: DROPPED ~p", [?MODULE, Count, TracingNode, OriginNode, MessagePayload]);
                                    forward_message ->
                                        lager:info("~p: ~p: ~p => ~p: DROPPED ~p", [?MODULE, Count, TracingNode, OriginNode, MessagePayload])
                                end;
                            _ ->
                                case InterpositionType of
                                    receive_message ->
                                        lager:info("~p: ~p: ~p <- ~p: REWROTE ~p to ~p", [?MODULE, Count, TracingNode, OriginNode, MessagePayload, RewrittenMessagePayload]);
                                    forward_message ->
                                        lager:info("~p: ~p: ~p => ~p: REWROTE ~p to ~p", [?MODULE, Count, TracingNode, OriginNode, MessagePayload, RewrittenMessagePayload])
                                end
                        end
                end;
            _ ->
                lager:info("~p: ~p: unknown message type: ~p, message: ~p", [?MODULE, Count, Type, Message])
        end,

        %% Advance line number.
        Count + 1
    end, 1, Trace),

    %% Write trace.
    case Replay of 
        true ->
            lager:info("~p: not writing trace, replay mode.", [?MODULE]),
            ok;
        false ->
            FilteredTrace = lists:filter(fun({Type, _Message}) ->
                case Type of 
                    pre_interposition_fun ->
                        true;
                    _ ->
                        false
                end
            end, Trace),
            lager:info("~p: writing trace.", [?MODULE]),
            ok = file:write_file(?FILENAME, term_to_binary(FilteredTrace))
    end,

    {reply, ok, State};
handle_call(Msg, _From, State) ->
    lager:warning("Unhandled call messages at module ~p: ~p", [?MODULE, Msg]),
    {reply, ok, State}.

%% @private
-spec handle_cast(term(), #state{}) -> {noreply, #state{}}.
handle_cast(Msg, State) ->
    lager:warning("Unhandled cast messages at module ~p: ~p", [?MODULE, Msg]),
    {noreply, State}.

%% @private
-spec handle_info(term(), #state{}) -> {noreply, #state{}}.
handle_info(Msg, State) ->
    lager:warning("Unhandled info messages at module ~p: ~p", [?MODULE, Msg]),
    {noreply, State}.

%% @private
-spec terminate(term(), #state{}) -> term().
terminate(_Reason, _State) ->
    ok.

%% @private
-spec code_change(term() | {down, term()}, #state{}, term()) -> {ok, #state{}}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private 
can_deliver_based_on_trace({Type, Message}, PreviousTrace) ->
    lager:info("~p: determining if message ~p: ~p can be delivered.", [?MODULE, Type, Message]),

    [{NextType, NextMessage} | _] = PreviousTrace,

    case {NextType, NextMessage} of 
        {Type, Message} ->
            lager:info("~p: => YES!", [?MODULE]),
            true;
        _ ->
            lager:info("~p: => NO, waiting for message: ~p: ~p", [?MODULE, NextType, NextMessage]),
            false
    end.

%% @private
trace_deliver([{_, _} | Trace], BlockedProcesses) ->
    lager:info("~p: delivering single message!", [?MODULE]),

    %% Advance the trace, then try to flush the blocked processes.
    trace_deliver_log_flush(Trace, BlockedProcesses).

%% @private
trace_deliver_log_flush(Trace0, BlockedProcesses0) ->
    lager:info("~p: attempting to flush blocked messages!", [?MODULE]),

    %% Iterate blocked processes in an attempt to remove one.
    {ND, T, BP} = lists:foldl(fun({{NextType, NextMessage}, Pid} = BP, {NumDelivered1, Trace1, BlockedProcesses1}) ->
        case can_deliver_based_on_trace({NextType, NextMessage}, Trace1) of 
            true ->
                lager:info("~p: pid ~p can be unblocked!", [?MODULE, Pid]),

                %% Advance the trace.
                [{_, _} | RestOfTrace] = Trace1,

                %% Advance the count of delivered messages.
                NewNumDelivered = NumDelivered1 + 1,

                %% Unblock the process.
                gen_server:reply(Pid, ok),

                %% Remove from the blocked processes list.
                NewBlockedProcesses = BlockedProcesses1 -- [BP],

                {NewNumDelivered, RestOfTrace, NewBlockedProcesses};
            false ->
                lager:info("~p: pid ~p CANNOT be unblocked yet, unmet dependencies!", [?MODULE, Pid]),

                {NumDelivered1, Trace1, BlockedProcesses1}
        end
    end, {0, Trace0, BlockedProcesses0}, BlockedProcesses0),

    %% Did we deliver something?  If so, try again.
    case ND > 0 of 
        true ->
            lager:info("~p: was able to deliver a message, trying again", [?MODULE]),
            trace_deliver_log_flush(T, BP);
        false ->
            lager:info("~p: flush attempt finished.", [?MODULE]),
            {T, BP}
    end.