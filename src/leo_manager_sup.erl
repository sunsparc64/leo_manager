%%======================================================================
%%
%% Leo Manaegr
%%
%% Copyright (c) 2012-2014 Rakuten, Inc.
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
%% ---------------------------------------------------------------------
%% Leo Manager - Supervisor.
%% @doc
%% @end
%%======================================================================
-module(leo_manager_sup).

-author('Yosuke Hara').

-behaviour(supervisor).

-include("leo_manager.hrl").
-include("tcp_server.hrl").
-include_lib("leo_commons/include/leo_commons.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_redundant_manager/include/leo_redundant_manager.hrl").
-include_lib("leo_statistics/include/leo_statistics.hrl").
-include_lib("leo_s3_libs/include/leo_s3_auth.hrl").
-include_lib("leo_s3_libs/include/leo_s3_user.hrl").
-include_lib("eunit/include/eunit.hrl").

%% External API
-export([start_link/0, stop/0]).
-export([create_mnesia_tables/2]).


%% Callbacks
-export([init/1]).

-define(CHECK_INTERVAL, 250).
-define(ENV_REPLICA_PARTNER, 'partner').


%%-----------------------------------------------------------------------
%% External API
%%-----------------------------------------------------------------------
%% @spec () -> ok
%% @doc start link...
%% @end
start_link() ->
    Mode = ?env_mode_of_manager(),
    Me = node(),

    {ReplicaNodes_1, ReplicaNodes_2} =
        case ?env_partner_of_manager_node() of
            [] ->
                {[Me] ,[{Mode, Me}]};
            Nodes_1 ->
                Nodes_2 = lists:map(fun(N) when is_atom(N) -> N;
                                       (N) -> list_to_atom(N)
                                    end, Nodes_1),
                {[Me|Nodes_2], [{Mode, Me},{?ENV_REPLICA_PARTNER, Nodes_2}]}
        end,

    %% Set mnesia's replica nodes in app-env
    leo_misc:init_env(),
    leo_misc:set_env(leo_redundant_manager, ?PROP_MNESIA_NODES, ReplicaNodes_1),

    case supervisor:start_link({local, ?MODULE}, ?MODULE, []) of
        {ok, Pid} ->
            %% Launch TCP-Server(s)
            CUI_Console  = #tcp_server_params{prefix_of_name  = "tcp_server_cui_",
                                              port = ?env_listening_port_cui(),
                                              num_of_listeners = ?env_num_of_acceptors_cui()},
            JSON_Console = #tcp_server_params{prefix_of_name  = "tcp_server_json_",
                                              port = ?env_listening_port_json(),
                                              num_of_listeners = ?env_num_of_acceptors_json()},
            PluginModConsole = ?env_plugin_mod_console(),
            ok = leo_manager_console:start_link(leo_manager_formatter_text, CUI_Console,  PluginModConsole),
            ok = leo_manager_console:start_link(leo_manager_formatter_json, JSON_Console, PluginModConsole),

            %% Launch Logger
            LogDir   = ?env_log_dir(),
            LogLevel = ?env_log_level(leo_manager),
            ok = leo_logger_client_message:new(
                   LogDir, LogLevel, log_file_appender()),

            %% Launch Statistics
            ok = leo_statistics_api:start_link(leo_manager),
            ok = leo_metrics_vm:start_link(?SNMP_SYNC_INTERVAL_10S),

            %% Launch MQ
            ok = leo_manager_mq_client:start(?MODULE, [], ?env_queue_dir()),

            %% Launch Redundant-manager
            SystemConf = leo_manager_api:load_system_config(),
            MembershipCallback = fun leo_manager_api:synchronize/1,

            ChildSpec = case Mode of
                            master ->
                                {leo_redundant_manager_sup,
                                 {leo_redundant_manager_sup, start_link,
                                  [Mode,
                                   ReplicaNodes_1,
                                   ?env_queue_dir(leo_manager),
                                   [{n,           SystemConf#?SYSTEM_CONF.n},
                                    {r,           SystemConf#?SYSTEM_CONF.r},
                                    {w,           SystemConf#?SYSTEM_CONF.w},
                                    {d,           SystemConf#?SYSTEM_CONF.d},
                                    {bit_of_ring, SystemConf#?SYSTEM_CONF.bit_of_ring},
                                    {num_of_dc_replicas,   SystemConf#?SYSTEM_CONF.num_of_dc_replicas},
                                    {num_of_rack_replicas, SystemConf#?SYSTEM_CONF.num_of_rack_replicas}
                                   ],
                                   MembershipCallback
                                  ]
                                 },
                                 permanent, 2000, supervisor, [leo_redundant_manager_sup]};
                            _ ->
                                {leo_redundant_manager_sup,
                                 {leo_redundant_manager_sup, start_link,
                                  [Mode,
                                   ReplicaNodes_1,
                                   ?env_queue_dir(leo_manager),
                                   [],
                                   MembershipCallback
                                  ]
                                 },
                                 permanent, 2000, supervisor, [leo_redundant_manager_sup]}
                        end,
            {ok, _} = supervisor:start_child(Pid, ChildSpec),

            %% Launch S3Libs:Auth/Bucket/EndPoint
            case ?env_use_s3_api() of
                false -> void;
                true  ->
                    ok = leo_s3_libs:start(master, [])
            end,

            %% launch leo_rpc's server
            ok = application:start(leo_rpc),

            %% Launch Mnesia and create that tables
            MnesiaDir = case application:get_env(mnesia, dir) of
                            {ok, Dir} -> Dir;
                            undefined -> ?DEF_MNESIA_DIR
                        end,
            case filelib:fold_files(MnesiaDir, "\\.DCD$", false,
                                    fun(X, Acc) ->
                                            [X|Acc]
                                    end, []) of
                [] ->
                    timer:apply_after(?CHECK_INTERVAL, ?MODULE,
                                      create_mnesia_tables, [Mode, ReplicaNodes_2]);
                _ ->
                    create_mnesia_tables_2()
            end,
            {ok, Pid};
        Error ->
            Error
    end.


%% @doc Create mnesia tables
%%
-spec(create_mnesia_tables(master | slave, atom()) ->
             ok | {error, any()}).
create_mnesia_tables(_, []) ->
    {error, badarg};
create_mnesia_tables(Mode, ReplicaNodes) ->
    case leo_misc:get_value(?ENV_REPLICA_PARTNER, ReplicaNodes) of
        undefined ->
            create_mnesia_tables_1(Mode, ReplicaNodes);
        PartnerNodes ->
            case lists:foldl(fun(N, _) ->
                                     case catch net_adm:ping(N) of
                                         pong -> true;
                                         _    -> false
                                     end
                             end, false, PartnerNodes) of
                true ->
                    create_mnesia_tables_1(Mode, ReplicaNodes);
                false ->
                    timer:apply_after(?CHECK_INTERVAL, ?MODULE,
                                      create_mnesia_tables, [Mode, ReplicaNodes])
            end
    end.


%% @spec () -> ok |
%%             not_started
%% @doc stop process.
%% @end
stop() ->
    case whereis(?MODULE) of
        Pid when is_pid(Pid) == true ->
            exit(Pid, shutdown),
            ok;
        _ -> not_started
    end.

%% ---------------------------------------------------------------------
%% Callbacks
%% ---------------------------------------------------------------------
%% @spec (Params) -> ok
%% @doc stop process.
%% @end
%% @private
init([]) ->
    ChildProcs = [
                  {tcp_server_sup,
                   {tcp_server_sup, start_link, []},
                   permanent,
                   ?SHUTDOWN_WAITING_TIME,
                   supervisor,
                   [tcp_server_sup]},

                  {leo_manager_cluster_monitor,
                   {leo_manager_cluster_monitor, start_link, []},
                   permanent,
                   ?SHUTDOWN_WAITING_TIME,
                   worker,
                   [leo_manager_cluster_monitor]}
                 ],
    {ok, {_SupFlags = {one_for_one, ?MAX_RESTART, ?MAX_TIME}, ChildProcs}}.


%% ---------------------------------------------------------------------
%% Inner Function(s)
%% ---------------------------------------------------------------------
%% @doc Create mnesia tables
%% @private
-spec(create_mnesia_tables_1(master | slave, list()) ->
             ok | {error, any()}).
create_mnesia_tables_1(master = Mode, Nodes) ->
    Nodes_1 = lists:flatten(lists:map(fun({_, N}) -> N end, Nodes)),
    case mnesia:create_schema(Nodes_1) of
        ok ->
            try
                %% create mnesia's schema
                rpc:multicall(Nodes_1, application, stop,  [mnesia], ?DEF_TIMEOUT),
                rpc:multicall(Nodes_1, application, start, [mnesia], ?DEF_TIMEOUT),

                %% create table into the mnesia
                leo_manager_mnesia:create_storage_nodes(disc_copies, Nodes_1),
                leo_manager_mnesia:create_gateway_nodes(disc_copies, Nodes_1),
                leo_manager_mnesia:create_rebalance_info(disc_copies, Nodes_1),
                leo_manager_mnesia:create_histories(disc_copies, Nodes_1),
                leo_manager_mnesia:create_available_commands(disc_copies, Nodes_1),

                leo_cluster_tbl_conf:create_table(disc_copies, Nodes_1),
                leo_mdcr_tbl_cluster_info:create_table(disc_copies, Nodes_1),
                leo_mdcr_tbl_cluster_stat:create_table(disc_copies, Nodes_1),
                leo_mdcr_tbl_cluster_mgr:create_table(disc_copies, Nodes_1),
                leo_mdcr_tbl_cluster_member:create_table(disc_copies, Nodes_1),
                leo_cluster_tbl_ring:create_table_current(disc_copies, Nodes_1),
                leo_cluster_tbl_ring:create_table_prev(disc_copies, Nodes_1),
                leo_cluster_tbl_member:create_table(disc_copies, Nodes_1, ?MEMBER_TBL_CUR),
                leo_cluster_tbl_member:create_table(disc_copies, Nodes_1, ?MEMBER_TBL_PREV),

                %% Load from system-config and store it into the mnesia
                {ok, _} = leo_manager_api:load_system_config_with_store_data(),

                %% Update available commands
                ok = leo_manager_mnesia:update_available_commands(?env_available_commands()),

                case ?env_use_s3_api() of
                    true ->
                        %% Create S3-related tables
                        leo_s3_auth:create_credential_table(disc_copies, Nodes_1),
                        leo_s3_endpoint:create_endpoint_table(disc_copies, Nodes_1),
                        leo_s3_bucket:create_bucket_table(disc_copies, Nodes_1),
                        leo_s3_user:create_user_table(disc_copies, Nodes_1),
                        leo_s3_user:create_user_credential_table(disc_copies, Nodes_1),

                        %% Insert test-related values
                        CreatedAt     = leo_date:now(),
                        leo_s3_libs_data_handler:insert({mnesia, leo_s3_users},
                                                        {[], #user{id         = ?TEST_USER_ID,
                                                                   role_id    = 9,
                                                                   created_at = CreatedAt}}),
                        leo_s3_libs_data_handler:insert({mnesia, leo_s3_user_credential},
                                                        {[], #user_credential{user_id       = ?TEST_USER_ID,
                                                                              access_key_id = ?TEST_ACCESS_KEY,
                                                                              created_at    = CreatedAt}}),
                        leo_s3_libs_data_handler:insert({mnesia, leo_s3_credentials},
                                                        {[], #credential{access_key_id     = ?TEST_ACCESS_KEY,
                                                                         secret_access_key = ?TEST_SECRET_KEY,
                                                                         created_at        = CreatedAt}}),
                        %% Insert default s3-endpoint values
                        leo_s3_endpoint:set_endpoint(?DEF_ENDPOINT_1),
                        leo_s3_endpoint:set_endpoint(?DEF_ENDPOINT_2);
                    false ->
                        void
                end,
                create_mnesia_tables_2()
            catch _:Reason ->
                    ?error("create_mnesia_tables_1/2", "cause:~p", [Reason])
            end,
            ok;
        {error,{_,{already_exists, _}}} ->
            create_mnesia_tables_2();
        {_, Cause} ->
            timer:apply_after(?CHECK_INTERVAL, ?MODULE, create_mnesia_tables, [Mode, Nodes]),
            ?error("create_mnesia_tables_1/2", "cause:~p", [Cause]),
            {error, Cause}
    end;
create_mnesia_tables_1(slave,_Nodes) ->
    create_mnesia_tables_2().

%% @doc Create mnesia tables and execute to migrate data
%% @private
-spec(create_mnesia_tables_2() ->
             ok | {error, any()}).
create_mnesia_tables_2() ->
    application:start(mnesia),
    case catch mnesia:system_info(tables) of
        Tbls when length(Tbls) > 1 ->
            ok = mnesia:wait_for_tables(Tbls, 60000),

            %% Execute to migrate data
            catch leo_manager_transformer:transform(),
            ok;
        Tbls when length(Tbls) =< 1 ->
            {error, no_exists};
        Error ->
            ?error("create_mnesia_tables_2/0", "cause:~p", [Error]),
            Error
    end.


%% @doc Get log-file appender from env
%% @private
-spec(log_file_appender() ->
             list()).
log_file_appender() ->
    case application:get_env(leo_manager, log_appender) of
        undefined   -> log_file_appender([], []);
        {ok, Value} -> log_file_appender(Value, [])
    end.

-spec(log_file_appender(list(), list()) ->
             list()).
log_file_appender([], []) ->
    [{?LOG_ID_FILE_INFO,  ?LOG_APPENDER_FILE},
     {?LOG_ID_FILE_ERROR, ?LOG_APPENDER_FILE}];
log_file_appender([], Acc) ->
    lists:reverse(Acc);
log_file_appender([{Type, _}|T], Acc) when Type == file ->
    log_file_appender(T, [{?LOG_ID_FILE_ERROR, ?LOG_APPENDER_FILE}|
                          [{?LOG_ID_FILE_INFO, ?LOG_APPENDER_FILE}|Acc]]).
