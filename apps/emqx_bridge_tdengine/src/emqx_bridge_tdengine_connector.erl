%%--------------------------------------------------------------------
%% Copyright (c) 2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------

-module(emqx_bridge_tdengine_connector).

-behaviour(emqx_resource).

-include_lib("typerefl/include/types.hrl").
-include_lib("emqx/include/logger.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include_lib("hocon/include/hoconsc.hrl").

-export([namespace/0, roots/0, fields/1, desc/1]).

%% `emqx_resource' API
-export([
    callback_mode/0,
    on_start/2,
    on_stop/2,
    on_query/3,
    on_batch_query/3,
    on_get_status/2,
    on_add_channel/4,
    on_remove_channel/3,
    on_get_channels/1,
    on_get_channel_status/3
]).

-export([connector_examples/1]).

-export([connect/1, do_get_status/1, execute/3, do_batch_insert/4]).

-import(hoconsc, [mk/2, enum/1, ref/2]).

-define(TD_HOST_OPTIONS, #{
    default_port => 6041
}).

-define(CONNECTOR_TYPE, tdengine).

namespace() -> "tdengine_connector".

%%=====================================================================
%% V1 Hocon schema
roots() ->
    [{config, #{type => hoconsc:ref(?MODULE, config)}}].

fields(config) ->
    base_config(true);
%%=====================================================================
%% V2 Hocon schema

fields("config_connector") ->
    emqx_connector_schema:common_fields() ++
        base_config(false) ++
        emqx_connector_schema:resource_opts_ref(?MODULE, connector_resource_opts);
fields(connector_resource_opts) ->
    emqx_connector_schema:resource_opts_fields();
fields("post") ->
    emqx_connector_schema:type_and_name_fields(enum([tdengine])) ++ fields("config_connector");
fields("put") ->
    fields("config_connector");
fields("get") ->
    emqx_bridge_schema:status_fields() ++ fields("post").

base_config(HasDatabase) ->
    [
        {server, server()}
        | adjust_fields(emqx_connector_schema_lib:relational_db_fields(), HasDatabase)
    ].

desc(config) ->
    ?DESC("desc_config");
desc(connector_resource_opts) ->
    ?DESC(emqx_resource_schema, "resource_opts");
desc("config_connector") ->
    ?DESC("desc_config");
desc(Method) when Method =:= "get"; Method =:= "put"; Method =:= "post" ->
    ["Configuration for TDengine using `", string:to_upper(Method), "` method."];
desc(_) ->
    undefined.

adjust_fields(Fields, HasDatabase) ->
    lists:filtermap(
        fun
            ({username, OrigUsernameFn}) ->
                {true, {username, add_default_fn(OrigUsernameFn, <<"root">>)}};
            ({password, _}) ->
                {true, {password, emqx_connector_schema_lib:password_field(#{required => true})}};
            ({database, _}) ->
                HasDatabase;
            (_Field) ->
                true
        end,
        Fields
    ).

add_default_fn(OrigFn, Default) ->
    fun
        (default) -> Default;
        (Field) -> OrigFn(Field)
    end.

server() ->
    Meta = #{desc => ?DESC("server")},
    emqx_schema:servers_sc(Meta, ?TD_HOST_OPTIONS).

%%=====================================================================
%% V2 Hocon schema
connector_examples(Method) ->
    [
        #{
            <<"tdengine">> =>
                #{
                    summary => <<"TDengine Connector">>,
                    value => emqx_connector_schema:connector_values(
                        Method, ?CONNECTOR_TYPE, connector_example_values()
                    )
                }
        }
    ].

connector_example_values() ->
    #{
        name => <<"tdengine_connector">>,
        type => tdengine,
        enable => true,
        server => <<"127.0.0.1:6041">>,
        pool_size => 8,
        username => <<"root">>,
        password => <<"******">>
    }.

%%========================================================================================
%% `emqx_resource' API
%%========================================================================================

callback_mode() -> always_sync.

on_start(
    InstanceId,
    #{
        server := Server,
        username := Username,
        password := Password,
        pool_size := PoolSize
    } = Config
) ->
    ?SLOG(info, #{
        msg => "starting_tdengine_connector",
        connector => InstanceId,
        config => emqx_utils:redact(Config)
    }),

    #{hostname := Host, port := Port} = emqx_schema:parse_server(Server, ?TD_HOST_OPTIONS),
    Options = [
        {host, to_bin(Host)},
        {port, Port},
        {username, Username},
        {password, Password},
        {pool_size, PoolSize},
        {pool, InstanceId}
    ],

    State = #{pool_name => InstanceId, channels => #{}},
    case emqx_resource_pool:start(InstanceId, ?MODULE, Options) of
        ok ->
            {ok, State};
        Error ->
            Error
    end.

on_stop(InstanceId, _State) ->
    ?SLOG(info, #{
        msg => "stopping_tdengine_connector",
        connector => InstanceId
    }),
    ?tp(tdengine_connector_stop, #{instance_id => InstanceId}),
    emqx_resource_pool:stop(InstanceId).

on_query(InstanceId, {ChannelId, Data}, #{channels := Channels} = State) ->
    case maps:find(ChannelId, Channels) of
        {ok, #{insert := Tokens, opts := Opts}} ->
            Query = emqx_placeholder:proc_tmpl(Tokens, Data),
            do_query_job(InstanceId, {?MODULE, execute, [Query, Opts]}, State);
        _ ->
            {error, {unrecoverable_error, {invalid_channel_id, InstanceId}}}
    end.

%% aggregate the batch queries to one SQL is a heavy job, we should put it in the worker process
on_batch_query(
    InstanceId,
    [{ChannelId, _Data = #{}} | _] = BatchReq,
    #{channels := Channels} = State
) ->
    case maps:find(ChannelId, Channels) of
        {ok, #{batch := Tokens, opts := Opts}} ->
            do_query_job(
                InstanceId,
                {?MODULE, do_batch_insert, [Tokens, BatchReq, Opts]},
                State
            );
        _ ->
            {error, {unrecoverable_error, {invalid_channel_id, InstanceId}}}
    end;
on_batch_query(InstanceId, BatchReq, State) ->
    LogMeta = #{connector => InstanceId, request => BatchReq, state => State},
    ?SLOG(error, LogMeta#{msg => "invalid_request"}),
    {error, {unrecoverable_error, invalid_request}}.

on_get_status(_InstanceId, #{pool_name := PoolName}) ->
    Health = emqx_resource_pool:health_check_workers(PoolName, fun ?MODULE:do_get_status/1),
    status_result(Health).

do_get_status(Conn) ->
    case tdengine:insert(Conn, "select server_version()", []) of
        {ok, _} -> true;
        _ -> false
    end.

status_result(_Status = true) -> connected;
status_result(_Status = false) -> connecting.

on_add_channel(
    _InstanceId,
    #{channels := Channels} = OldState,
    ChannelId,
    #{
        parameters := #{database := Database, sql := SQL}
    }
) ->
    case maps:is_key(ChannelId, Channels) of
        true ->
            {error, already_exists};
        _ ->
            case parse_prepare_sql(SQL) of
                {ok, Result} ->
                    Opts = [{db_name, Database}],
                    Channels2 = Channels#{ChannelId => Result#{opts => Opts}},
                    {ok, OldState#{channels := Channels2}};
                Error ->
                    Error
            end
    end.

on_remove_channel(_InstanceId, #{channels := Channels} = OldState, ChannelId) ->
    {ok, OldState#{channels => maps:remove(ChannelId, Channels)}}.

on_get_channels(InstanceId) ->
    emqx_bridge_v2:get_channels_for_connector(InstanceId).

on_get_channel_status(InstanceId, ChannelId, #{channels := Channels} = State) ->
    case maps:is_key(ChannelId, Channels) of
        true ->
            on_get_status(InstanceId, State);
        _ ->
            {error, not_exists}
    end.

%%========================================================================================
%% Helper fns
%%========================================================================================

do_query_job(InstanceId, Job, #{pool_name := PoolName} = State) ->
    ?TRACE(
        "QUERY",
        "tdengine_connector_received",
        #{connector => InstanceId, job => Job, state => State}
    ),
    Result = ecpool:pick_and_do(PoolName, Job, no_handover),
    case Result of
        {error, Reason} ->
            ?tp(
                tdengine_connector_query_return,
                #{instance_id => InstanceId, error => Reason}
            ),
            ?SLOG(error, #{
                msg => "tdengine_connector_do_query_failed",
                connector => InstanceId,
                job => Job,
                reason => Reason
            }),
            case Reason of
                ecpool_empty ->
                    {error, {recoverable_error, Reason}};
                _ ->
                    Result
            end;
        _ ->
            ?tp(
                tdengine_connector_query_return,
                #{instance_id => InstanceId, result => Result}
            ),
            Result
    end.

execute(Conn, Query, Opts) ->
    tdengine:insert(Conn, Query, Opts).

do_batch_insert(Conn, Tokens, BatchReqs, Opts) ->
    SQL = aggregate_query(Tokens, BatchReqs, <<"INSERT INTO">>),
    execute(Conn, SQL, Opts).

aggregate_query(BatchTks, BatchReqs, Acc) ->
    lists:foldl(
        fun({_, Data}, InAcc) ->
            InsertPart = emqx_placeholder:proc_tmpl(BatchTks, Data),
            <<InAcc/binary, " ", InsertPart/binary>>
        end,
        Acc,
        BatchReqs
    ).

connect(Opts) ->
    %% TODO: teach `tdengine` to accept 0-arity closures as passwords.
    {value, {password, Secret}, OptsRest} = lists:keytake(password, 1, Opts),
    NOpts = [{password, emqx_secret:unwrap(Secret)} | OptsRest],
    tdengine:start_link(NOpts).

parse_prepare_sql(SQL) ->
    case emqx_utils_sql:get_statement_type(SQL) of
        insert ->
            InsertTks = emqx_placeholder:preproc_tmpl(SQL),
            SQL1 = string:trim(SQL, trailing, ";"),
            case split_insert_sql(SQL1) of
                [_InsertPart, BatchDesc] ->
                    BatchTks = emqx_placeholder:preproc_tmpl(BatchDesc),
                    {ok, #{insert => InsertTks, batch => BatchTks}};
                Result ->
                    {error, #{msg => "split_sql_failed", sql => SQL, result => Result}}
            end;
        Type when is_atom(Type) ->
            {error, #{msg => "detect_sql_type_unsupported", sql => SQL, type => Type}};
        {error, Reason} ->
            {error, #{msg => "detect_sql_type_failed", sql => SQL, reason => Reason}}
    end.

to_bin(List) when is_list(List) ->
    unicode:characters_to_binary(List, utf8).

split_insert_sql(SQL0) ->
    SQL = formalize_sql(SQL0),
    lists:filtermap(
        fun(E) ->
            case string:trim(E) of
                <<>> ->
                    false;
                E1 ->
                    {true, E1}
            end
        end,
        re:split(SQL, "(?i)(insert into)")
    ).

formalize_sql(Input) ->
    %% 1. replace all whitespaces like '\r' '\n' or spaces to a single space char.
    SQL = re:replace(Input, "\\s+", " ", [global, {return, binary}]),
    %% 2. trims the result
    string:trim(SQL).
