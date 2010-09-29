%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ Management Console.
%%
%%   The Initial Developers of the Original Code are Rabbit Technologies Ltd.
%%
%%   Copyright (C) 2010 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%
-module(rabbit_mgmt_util).

%% TODO sort all this out; maybe there's scope for rabbit_mgmt_request?

-export([is_authorized/2, is_authorized_admin/2, vhost/1]).
-export([is_authorized_vhost/2, is_authorized/3, is_authorized_user/3]).
-export([bad_request/3, id/2, parse_bool/1, now_ms/0]).
-export([with_decode/4, not_found/3, not_authorised/3, amqp_request/4]).
-export([all_or_one_vhost/2, with_decode_vhost/4, reply/3, filter_vhost/3]).
-export([filter_user/3, with_decode/5, redirect/2, args/1]).

-include("rabbit_mgmt.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

%%--------------------------------------------------------------------

is_authorized(ReqData, Context) ->
    is_authorized(ReqData, Context, fun(_) -> true end).

is_authorized_admin(ReqData, Context) ->
    is_authorized(ReqData, Context,
                  fun(#user{is_admin = IsAdmin}) -> IsAdmin end).

is_authorized_vhost(ReqData, Context) ->
    is_authorized(ReqData, Context,
                  fun(#user{username = Username}) ->
                          case vhost(ReqData) of
                              not_found -> true;
                              none      -> true;
                              V         -> lists:member(V, vhosts(Username))
                          end
                  end).

is_authorized_user(ReqData, Context, Item) ->
    is_authorized(
      ReqData, Context,
      fun(#user{username = Username, is_admin = IsAdmin}) ->
              IsAdmin orelse Username == proplists:get_value(user, Item)
      end).

is_authorized(ReqData, Context, Fun) ->
    Unauthorized = {"Basic realm=\"RabbitMQ Management Console\"",
                    ReqData, Context},
    case wrq:get_req_header("authorization", ReqData) of
        "Basic " ++ Base64 ->
            Str = base64:mime_decode_to_string(Base64),
            [Username, Pass] =
                [list_to_binary(S) || S <- string:tokens(Str, ":")],
            case rabbit_access_control:lookup_user(Username) of
                {ok, User = #user{password = Pass1,
                                  is_admin = IsAdmin}} when Pass == Pass1  ->
                    case Fun(User) of
                        true  -> {true, ReqData,
                                  Context#context{username = Username,
                                                  password = Pass,
                                                  is_admin = IsAdmin}};
                        false -> Unauthorized
                    end;
                {ok, #user{}} ->
                    Unauthorized;
                {error, _} ->
                    Unauthorized
            end;
        _ ->
            Unauthorized
    end.

now_ms() ->
    rabbit_mgmt_format:timestamp(now()).

vhost(ReqData) ->
    case id(vhost, ReqData) of
        none  -> none;
        VHost -> case rabbit_access_control:vhost_exists(VHost) of
                     true  -> VHost;
                     false -> not_found
                 end
    end.

reply(Facts, ReqData, Context) ->
    ReqData1 = wrq:set_resp_header("Cache-Control", "no-cache", ReqData),
    {mochijson2:encode(Facts), ReqData1, Context}.

bad_request(Reason, ReqData, Context) ->
    halt_response(400, bad_request, Reason, ReqData, Context).

not_authorised(Reason, ReqData, Context) ->
    halt_response(401, not_authorised, Reason, ReqData, Context).

not_found(Reason, ReqData, Context) ->
    halt_response(404, not_found, Reason, ReqData, Context).

halt_response(Code, Type, Reason, ReqData, Context) ->
    Json = {struct, [{error, Type},
                     {reason, rabbit_mgmt_format:tuple(Reason)}]},
    ReqData1 = wrq:append_to_response_body(mochijson2:encode(Json), ReqData),
    {{halt, Code}, ReqData1, Context}.

id(exchange, ReqData) ->
    case id0(exchange, ReqData) of
        <<"amq.default">> -> <<"">>;
        Name              -> Name
    end;
id(Key, ReqData) ->
    id0(Key, ReqData).

id0(Key, ReqData) ->
    case dict:find(Key, wrq:path_info(ReqData)) of
        {ok, Id} -> list_to_binary(mochiweb_util:unquote(Id));
        error    -> none
    end.

with_decode(Keys, ReqData, Context, Fun) ->
    with_decode(Keys, wrq:req_body(ReqData), ReqData, Context, Fun).

with_decode(Keys, Body, ReqData, Context, Fun) ->
    case decode(Keys, Body) of
        {error, Reason} -> bad_request(Reason, ReqData, Context);
        Values          -> try
                               Fun(Values)
                           catch {error, Error} ->
                                   bad_request(Error, ReqData, Context)
                           end
    end.

decode(Keys, Body) ->
    {Res, Json} = try
                      {struct, J} = mochijson2:decode(Body),
                      {ok, J}
                  catch error:_ -> {error, not_json}
                  end,
    case Res of
        ok -> Results =
                  [get_or_missing(list_to_binary(atom_to_list(K)), Json) ||
                      K <- Keys],
              case [E || E = {key_missing, _} <- Results] of
                  []      -> Results;
                  Errors  -> {error, Errors}
              end;
        _  -> {Res, Json}
    end.

with_decode_vhost(Keys, ReqData, Context, Fun) ->
    case vhost(ReqData) of
        not_found -> not_found(vhost_not_found, ReqData, Context);
        VHost     -> with_decode(Keys, ReqData, Context,
                                 fun (Vals) -> Fun(VHost, Vals) end)
    end.

get_or_missing(K, L) ->
    case proplists:get_value(K, L) of
        undefined -> {key_missing, K};
        V         -> V
    end.

parse_bool(<<"true">>)  -> true;
parse_bool(<<"false">>) -> false;
parse_bool(true)        -> true;
parse_bool(false)       -> false;
parse_bool(V)           -> throw({error, {not_boolean, V}}).

amqp_request(VHost, ReqData, Context, Method) ->
    try
        Params = #amqp_params{username = Context#context.username,
                              password = Context#context.password,
                              virtual_host = VHost},
        case amqp_connection:start(direct, Params) of
            {ok, Conn} ->
                {ok, Ch} = amqp_connection:open_channel(Conn),
                amqp_channel:call(Ch, Method),
                amqp_channel:close(Ch),
                amqp_connection:close(Conn),
                {true, ReqData, Context};
            {error, {auth_failure_likely,
                     {#amqp_error{name = access_refused}, _}}} ->
                not_authorised(not_authorised, ReqData, Context);
            {error, #amqp_error{name = {error, Error}}} ->
                bad_request(Error, ReqData, Context)
        end
        %% See bug 23187
    catch
        exit:{{server_initiated_close, ?NOT_FOUND, Reason}, _} ->
            not_found(list_to_binary(Reason), ReqData, Context);
        exit:{{server_initiated_close, _Code, Reason}, _} ->
            bad_request(list_to_binary(Reason), ReqData, Context)
    end.

all_or_one_vhost(ReqData, Fun) ->
    case rabbit_mgmt_util:vhost(ReqData) of
        none      -> lists:append(
                       [Fun(V) || V <- rabbit_access_control:list_vhosts()]);
        not_found -> vhost_not_found;
        VHost     -> Fun(VHost)
    end.

filter_vhost(List, _ReqData, Context) ->
    VHosts = vhosts(Context#context.username),
    [I || I <- List, lists:member(proplists:get_value(vhost, I), VHosts)].

vhosts(Username) ->
    [VHost || {VHost, _, _, _, _}
                  <- rabbit_access_control:list_user_permissions(Username)].

filter_user(List, _ReqData, #context{is_admin = true}) ->
    List;
filter_user(List, _ReqData, #context{username = Username, is_admin = false}) ->
    [I || I <- List, proplists:get_value(user, I) == Username].

redirect(Location, ReqData) ->
    wrq:do_redirect(true,
                    wrq:set_resp_header("Location",
                                        binary_to_list(Location), ReqData)).
args({struct, L}) ->
    args(L);
args(L) ->
    [{K, rabbit_mgmt_format:args_type(V), V} || {K, V} <- L].
