%% @doc This is a module.
%% @author Ángel Herranz (aherranz@fi.upm.es), Lars-Ake Fredlund
%% (lfredlund@fi.upm.es), Sergio Gil (sergio.gil.luque@gmail.com)
%% @copyright 2013 Ángel Herranz, Lars-Ake Fredlund, Sergio Gil
%% @end
%%


-module(js_links_machine).

-export([run_statem/1,run_statem/2,run_statem/3 , format_http_call/1,
         http_result_code/1, http_error/1, collect_links/1,
         collect_schema_links/2, init_table/2, test/0,
         initial_state/0, api_spec/0, link/2, call_link_title/1,
         validate_call_not_error_result/2, response_has_body/1,
         get_json_body/1]).

-compile([{nowarn_unused_function, [ prop_ok/0
                                   , start/0
                                   , print_counterexample/4
                                   , print_commands/1
                                   , print_stats/0
                                   , call_link/1
                                   , private_module/0
                                   , http_request/6
                                   , gen_headers/2, gen_header/2
                                   , has_ets_body/1
                                   , http_version/1
                                   , wait_until_stable/0
                                   , wait_forever/0
                                   , eqc_printer/2
                                   , args_link_title/1
                                   , initial_links/0
                                   , http_reason_phrase/1
                                   , http_response_is_ok/1
                                   , json_call_body/1
                                   ]}]).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eqc/include/eqc_component.hrl").
-include_lib("eqc/include/eqc_dynamic_cluster.hrl").
-include_lib("jsongen.hrl").

%% Super fragile below
-record(eqc_statem_history,{state, args, call, features, result}).

%%-define(debug,true).

-ifdef(debug).
-define(LOG(X,Y),
        io:format("{~p,~p}: ~s~n", [?MODULE,?LINE,io_lib:format(X,Y)])).
-else.
-define(LOG(X,Y),true).
-endif.

-type filename() :: string().

                                                % Not used
api_spec() ->
  #api_spec{}.

initial_state() ->
  PrivateState =
    case exists_private_function(initial_state,0) of
      true ->
        (private_module()):initial_state();
      false ->
        void
    end,
  #state
    {static_links=initial_links(),
     initialized=false,
     dynamic_links=jsl_dynamic_links:initialize(20),
     private_state=PrivateState}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_pre(State) ->
  not(State#state.initialized).

start_args(_State) ->
  [].

start() ->
  %%jsg_store:open_clean_db(),
  jsg_utils:clear_schema_cache(),
  true = ets:match_delete(jsg_store,{{object,'_'},'_'}),
  true = ets:match_delete(jsg_store,{{term,'_'},'_'}),
  true = ets:match_delete(jsg_store,{{link,'_'},'_'}),
  true = ets:match_delete(jsg_store,{{reverse_link,'_'},'_'}),
  httpc:reset_cookies().

start_next(State,_,_) ->
  State#state{initialized=true}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

link_pre(State) ->
  State#state.initialized.

link_args(State) ->
  case jsl_dynamic_links:is_empty(State#state.dynamic_links) of
    true ->
      ?LET(FinalLink,
           eqc_gen:oneof(State#state.static_links),
           gen_call(FinalLink));
    false ->
      ?LET
         (FinalLink,
          eqc_gen:
            frequency
              ([{2,
                 ?LET
                    (Title,
                     eqc_gen:oneof
                       (jsl_dynamic_links:titles
                          (State#state.dynamic_links)),
                     eqc_gen:oneof
                       (jsl_dynamic_links:links
                          (Title,State#state.dynamic_links)))},
                {1,
                 eqc_gen:oneof(State#state.static_links)}]),
          gen_call(FinalLink))
  end.

link_pre(State,[Link,_]) ->
  (State#state.initialized==true)
    andalso ((jsg_links:link_type(Link)==static)
             orelse
             jsl_dynamic_links:is_element(Link,State#state.dynamic_links))
    andalso link_permitted(State,Link).

link_permitted(State,Link) ->
  make_call(link_permitted,fun link_permitted_int/2,[State,Link]).

link_permitted_int(_State,_Link) ->
  true.

gen_call(Link) -> % generator :: [Link, {BinaryUri,Requesttype,Body,Parms}]
  ?LET(Parms,
       gen_http_request(Link),
       [Link,Parms]).

link_post(_State,Args,{'EXIT',Error}) ->
  error_messages:erlang_exception(Args, Error),
  error(bad_link);
link_post(State,Args,Result) ->
  try make_call(postcondition,fun postcondition_int/3,[State,Args,Result])
  catch Class:Reason ->
      io:format
        ("Warning: postcondition/3 raises exception ~p~n",
         [Reason]),
      StackTrace = erlang:get_stacktrace(),
      erlang:raise(Class,Reason,StackTrace)
  end.

postcondition_int(_State,Args,Result) ->
  case validate_call_not_error_result(Args,Result) of
    true ->
      Link = jsg_links:link_def(args_link(Args)),
      Schema = jsg_links:link_schema(args_link(Args)),
      case response_has_body(Result) of
        true ->
          validate_call_result_body(Args, Result, Link, Schema) and
            validate_response_code(Args, Result, Link, Schema);
        false ->
          validate_no_body_response(Args, Result, Link)
      end;
    _ ->
      io:format("validation failed~n"),
      false
  end.

validate_call_not_error_result(Args,Result) ->
  case http_result_type(Result) of
    ok ->
      true;
    {error,_Error} ->
      error_messages:wrong_http_call(Args, Result),
      false
  end.

validate_call_result_body(Args,Result,Link,Schema) ->
  case jsg_jsonschema:propertyValue(Link,"targetSchema") of
    undefined ->
      true;
    TargetSchema ->
      RealTargetSchema = jsg_links:get_schema(TargetSchema,Schema),
      case response_has_json_body(Result) of
        false ->
          false;
        true ->
          Body = http_body(Result),
          Validator = get_option(validator),
          try Validator:validate(RealTargetSchema,Body)
          catch _Class:Reason ->
              error_messages:wrong_body_message(Args, Body, RealTargetSchema, Reason),
              io:format
                ("Stacktrace:~n~p~n",
                 [erlang:get_stacktrace()]),
              false
          end
      end
  end.

validate_no_body_response(Args, Result, Link) ->
  case jsg_jsonschema:propertyValue(Link, "targetSchema") of
    undefined -> true;
    TargetSchema ->
      Errors = jsg_jsonschema:propertyValue(TargetSchema, "error"),
      case
        case Errors of
          undefined ->
            error_messages:unknown_status(Args, http_result_code(Result)),
            true;
          _ ->
            lists:member(http_result_code(Result), Errors)
        end
      of
        false ->
          error_messages:wrong_status_code(Args, Result, Errors),
          false;
        true ->
          true
      end
  end.

validate_response_code(Args, Result, Link, Schema) ->
  case jsg_jsonschema:propertyValue(Link, "targetSchema") of
    undefined -> true;
    TargetSchema ->
      RealTargetSchema = jsg_links:get_schema(TargetSchema, Schema),
      SchemaStatusCode = get_status_code(RealTargetSchema),
      case
        case SchemaStatusCode of
          undefined ->
            http_result_code(Result) == 200;
          {SpecialType, ListOfSchemasAndStatus} ->
            validate_list_of_schemas(SpecialType, ListOfSchemasAndStatus,
                                     http_result_code(Result), http_body(Result));
          SchemaStatusCode ->
            SchemaStatusCode == http_result_code(Result)
        end
      of
        false ->
          error_messages:wrong_status_code(Args, Result, SchemaStatusCode),
          false;
        true -> true;
        Errors ->
          lists:map(fun({StatusCode, Header, Body}) ->
                        error_messages:wrong_body_message(StatusCode, Header, Body)
                    end, Errors),
          false
      end
  end.

get_status_code(Schema={struct, ListOfValues}) ->
  case ListOfValues of
    [{<<"oneOf">>, JsonSchemaList}] ->
      {one_of, lists:map(fun(X) -> {get_status_code(X), X} end, JsonSchemaList)};
    [{<<"anyOf">>, JsonSchemaList}] ->
      {any_of, lists:map(fun(X) -> {get_status_code(X), X} end, JsonSchemaList)};
    [{<<"$ref">>, _}] ->
      get_status_code(jsg_links:get_schema(Schema));
    %% [{<<"allOf">>, JsonSchemaList}] ->
    %%     lists:map(fun(X) -> get_status_code(X) end, JsonSchemaList);
    %% [{<<"none">>, JsonSchemaList}] ->
    %%     lists:map(fun(X) -> get_status_code(X) end, JsonSchemaList);
    _ ->
      jsg_jsonschema:propertyValue(Schema, "status")
  end.

validate_list_of_schemas(one_of, List, StatusCode, Body) ->
  ValidationResult = lists:map(fun(X) -> validate_header_and_schema(X, StatusCode, Body) end, List),
  case length(lists:filter(fun(X) -> X == {true, true} end, ValidationResult)) of
    1 -> true;
    _ -> get_wrong_status_list(StatusCode, Body, lists:zip(ValidationResult, List))
  end;
validate_list_of_schemas(any_of, List, StatusCode, Body) ->
  ValidationResult = lists:map(fun(X) -> validate_header_and_schema(X, StatusCode, Body) end, List),
  case length(lists:filter(fun(X) -> X == {true, true} end, ValidationResult)) of
    0 -> get_wrong_status_list(StatusCode, Body, lists:zip(ValidationResult, List));
    _ -> true
  end.

validate_header_and_schema({Header, Schema}, StatusCode, Body) ->
  Validator = get_option(validator),
  {
    case Header of
      undefined -> StatusCode == 200;
      _ -> Header == StatusCode
    end,
    try Validator:validate(Schema, Body, no_report)
    catch _:_ -> false end
  }.

get_wrong_status_list(StatusCode, Body, List) ->
  lists:foldl(fun({X, {Header, _}}, Acc) ->
                  case X of
                    {false, true} -> [{StatusCode, Header, Body}|Acc];
                    _ -> Acc
                  end
              end, [], List).

link_next(State,Result,Args) ->
  try make_call(next_state,fun next_state_int/3,[State,Result,Args])
  catch Class:Reason ->
      io:format
        ("Warning: next_state/3 raises exception ~p~n",
         [Reason]),
      StackTrace = erlang:get_stacktrace(),
      erlang:raise(Class,Reason,StackTrace)
  end.

next_state_int(State,Result,[Link,_]) ->
  case Result of
    {ok,{{_,_Code,_},_Headers,_Body}} ->
      LinksToAdd =
        case response_has_body(Result) of
          true ->
            JSONbody = mochijson2:decode(http_body(Result)),
            jsg_links:extract_dynamic_links
              (Link,JSONbody,jsg_links:intern_object(JSONbody));
          _ ->
            []
        end,
      State#state
        {
        dynamic_links=
          lists:foldl
            (fun (DLink,DLs) ->
                 jsl_dynamic_links:add_link(DLink,DLs)
             end, State#state.dynamic_links, LinksToAdd)
       };
    _Other ->
      State
  end.

make_call(ExternalFunction,InternalFunction,Args) ->
  [{private_module,Module}] =
    ets:lookup(js_links_machine_data,private_module),
  {arity,Arity} = erlang:fun_info(InternalFunction,arity),
  case exists_private_function(ExternalFunction,Arity+1) of
    true ->
      apply(Module,ExternalFunction,[InternalFunction|Args]);
    false ->
      ?LOG
         ("function ~p:~p/~p missing~n",
          [Module,ExternalFunction,Arity+1]),
      apply(InternalFunction,Args)
  end.

exists_private_function(Function,Arity) ->
  [{private_module,Module}] =
    ets:lookup(js_links_machine_data,private_module),
  try Module:module_info(exports) of
      Exports -> lists:member({Function,Arity},Exports)
  catch _:_ -> false end.

private_module() ->
  [{private_module,Module}] =
    ets:lookup(js_links_machine_data,private_module),
  Module.

initial_links() ->
  [{initial_links,Links}] =
    ets:lookup(js_links_machine_data,initial_links),
  Links.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

gen_http_request(Link) -> % generator :: [{BinaryUri,Requesttype,Body,Parms}]
  ?LET({Body,QueryParms,Headers},
       {generate_body(Link),generate_parameters(Link),generate_headers(Link)},
       begin
         PreURI = jsg_links:link_calculated_href(Link),
         RequestType = jsg_links:link_request_type(Link),
         EncodedParms = encode_generated_parameters(QueryParms), % enco..ters :: [{key,value}]
         case re:split(PreURI,"\\?") of
           [_] ->
             {binary_to_list(PreURI),RequestType,Body,EncodedParms,Headers};
           [BinaryURI,BinaryParms] ->
             {binary_to_list(BinaryURI),RequestType,Body,
              split_parms(BinaryParms)++EncodedParms,Headers} % split_parms :: [{key,value}]
         end
       end).

generate_headers({link, Props}) -> proplists:get_value(headers, Props).

generate_body(Link) ->
  Sch = jsg_links:link_def(Link),
  Schema = jsg_jsonschema:propertyValue(Sch,"schema"),
  RequestType = jsg_links:link_request_type(Link),
  case may_have_body(RequestType) of
    true when Schema=/=undefined ->
      {ok,jsongen:json(Schema)};
    _ ->
      undefined
  end.

generate_parameters(Link) ->
  Sch = jsg_links:link_def(Link),
  Schema = jsg_jsonschema:propertyValue(Sch,"schema"),
  QuerySchema = jsg_jsonschema:propertyValue(Sch,"querySchema"),
  RequestType = jsg_links:link_request_type(Link),
  case may_have_body(RequestType) of
    true when QuerySchema=/=undefined ->
      jsongen:json(QuerySchema);
    false when QuerySchema=/=undefined ->
      jsongen:json(QuerySchema);
    false when Schema=/=undefined ->
      jsongen:json(Schema);
    _ ->
      undefined
  end.

may_have_body(get) ->
  false;
may_have_body(delete) ->
  false;
may_have_body(_) ->
  true.

split_parms(BinaryParms) ->
  case re:split(BinaryParms,"&") of
    [_] ->
      [Key,Value] = re:split(BinaryParms,"="),
      [{binary_to_list(Key),binary_to_list(Value)}];
    Assignments ->
      lists:flatmap(fun split_parms/1, Assignments)
  end.

link(Link,_HTTPRequest={URI,RequestType,Body,QueryParms,Headers}) ->
  try
    case jsg_links:link_title(Link) of
      String when is_list(String) ->
        Key = list_to_atom(String),
        {ok,Stats} = jsg_store:get(stats),
        NewValue =
          case lists:keyfind(Key,1,Stats) of
            false -> 1;
            {_,N} -> N+1
          end,
        jsg_store:put(stats,lists:keystore(Key,1,Stats,{Key,NewValue}));
      _ -> ok
    end,
    GeneratedHeaders=gen_headers(Headers,Body),
    Result = http_request(URI,RequestType,Body,QueryParms,Link,GeneratedHeaders),
    jsg_store:put(last_headers,GeneratedHeaders),
    case Result of
      {error,Error} ->
        io:format
          ("Warning: link/3 returned an error ~p, raising exception~n",
           [Error]),
        throw({error,Error});
      _ -> ok
    end,
    case response_has_body(Result) of
      true ->
        %% ResponseBody = http_body(Result),
        %% case false of
        %%   %% case length(ResponseBody)>1024 of
        %%   true ->
        %%     jsg_store:put(last_body,{body,ResponseBody}),
        %%     {P1,{P2,P3,_}} = Result,
        %%     {P1,{P2,P3,ets_body}};
        %%   false ->
        jsg_store:put(last_body,has_body),
        Result;
      %% end;
      false ->
        jsg_store:put(last_body,no_body),
        Result
    end
  catch Class:Reason ->
      case {Class,Reason} of
        {throw,{error,_}} ->
          {'EXIT',Reason};
        _ ->
          io:format("Warning: link/3 raised exception ~p~n",[Reason]),
          {'EXIT',Reason}
      end
  end.

format_http_call([_,{URI,RequestType,Body,Params,_Headers}]) ->
  format_http_call(URI,RequestType,Body,Params).

format_http_call(PreURI,RequestType,Body,Params) ->
  BodyString =
    case Body of
      {ok,JSON} ->
        io_lib:format(" body=~s",[mochijson2:encode(JSON)]);
      _ ->
        ""
    end,
  URI =
    case Params of
      [] -> PreURI;
      _ -> PreURI++"?"++encode_parameters(Params)
    end,
  io_lib:format
    ("~s using ~s~s",
     [URI,string:to_upper(atom_to_list(RequestType)),BodyString]).

%% has_body(get) ->
%%   false;
%% has_body(delete) ->
%%   false;
%% has_body(_) ->
%%   true.

encode_generated_parameters(Parms) ->
  case Parms of
    {ok,{struct,L}} ->
      lists:map
        (fun ({Key,Value}) ->
             {to_list(Key), to_list(Value)}
         end, L);
    _ -> []
  end.

to_list(B) when is_binary(B) ->
  binary_to_list(B);
to_list(I) when is_integer(I) ->
  integer_to_list(I).

encode_parameters([]) -> "";
encode_parameters([{Key,Value}|Rest]) ->
  Continuation =
    if
      Rest==[] -> "";
      true -> "&"++encode_parameters(Rest)
    end,
  Key++"="++encode(Value)++Continuation.

encode(String) when is_list(String) ->
  http_uri:encode(String).

http_request(PreURI,Type,Body,QueryParms,Link,Headers) ->
  URI =
    case QueryParms of
      [] -> PreURI;
      _ -> PreURI++"?"++encode_parameters(QueryParms)
    end,
  URIwithBody =
    case Body of
      {ok, RawBody} ->
        {URI, Headers, "application/json", iolist_to_binary(mochijson2:encode(RawBody))};
      _ ->
        {URI, Headers}
    end,
  Timeout = get_option(timeout),
  Request = [Type,URIwithBody,[{timeout,Timeout}],[]],
  case get_option(show_uri) of
    true -> io:format("Accessing URI ~p~n",[URI]);
    false -> ok
  end,
  {ElapsedTime,Result} =
    case get_option(simulation_mode) of
      false ->
        timer:tc(httpc,request,Request);
      true ->
        TargetSchema =
          jsg_links:get_schema(jsg_links:link_targetSchema(Link)),
        ResponseBody =
          case TargetSchema of
            undefined ->
              eqc_gen:pick(jsongen:anyType());
            _ ->
              eqc_gen:pick(jsongen:json(TargetSchema))
          end,
        EncodedBody = mochijson2:encode(ResponseBody),
        Headers = {"HTTP/1.1",200,"OK"},
        StatusLine = [{"content-length",integer_to_list(length(EncodedBody))},
                      {"content-type","application/json;charset=UTF-8"}],
        {1000,{ok,{Headers,StatusLine,EncodedBody}}}
    end,
  case get_option(show_http_timing) of
    true -> io:format("http request took ~p milliseconds~n",[ElapsedTime/1000]);
    false -> ok
  end,
  case get_option(show_http_result) of
    true -> io:format("result: ~p~n", [Result]);
    false -> ok
  end,
  Result.

gen_headers([], _) ->
  case {get_option(user), get_option(password)} of
    {false, _} -> [];
    {_, false} -> [];
    {User, Password} ->
      [{"Authorization", "Basic " ++ base64:encode_to_string(User ++ ":" ++ Password)}]
  end;
gen_headers(Headers, Body) -> lists:map(fun(Header) -> gen_header(Header, Body) end, Headers).

gen_header({struct, PropList}, _) ->
  {User, Password} =
    case
      case {proplists:get_value(<<"user">>, PropList, undefined),
            proplists:get_value(<<"password">>, PropList, undefined)} of
        {undefined, _} ->
          {get_option(user), get_option(password)};
        {_, undefined} ->
          {get_option(user), get_option(password)};
        X -> X
      end
    of
      {undefined, _} -> {"", ""};
      {Y, undefined} -> {Y, ""};
      Y -> Y
    end,
  {"Authorization", "Basic " ++ base64:encode_to_string(<<User/binary, ":", Password/binary>>)};
gen_header({quickcheck, QcGen}, Body) -> eqc_gen:pick(QcGen(Body));
gen_header(Header, _) -> Header.

http_result_type({ok,_}) ->
  ok;
http_result_type(Other) ->
  Other.

http_error({error,Error}) ->
  Error.

http_headers({ok,{_,Headers,_}}) ->
  Headers.

http_body({ok,{_,_,Body}}) ->
  case Body of
    ets_body ->
      {ok,{body,RealBody}} = jsg_store:get(last_body),
      RealBody;
    _ ->
      Body
  end.

has_ets_body({ok,{_,_,Body}}) ->
  case Body of
    ets_body ->
      true;
    _ ->
      false
  end.

http_status_line({ok,{StatusLine,_,_}}) ->
  StatusLine.

http_version(Result) ->
  case http_status_line(Result) of
    {Version,_,_} ->
      Version
  end.

http_result_code(Result) ->
  case http_status_line(Result) of
    {_,ResultCode,_} ->
      ResultCode
  end.

http_reason_phrase(Result) ->
  case http_status_line(Result) of
    {_,_,ReasonPhrase} ->
      ReasonPhrase
  end.

http_response_is_ok(Result) ->
  case http_result_type(Result) of
    ok ->  http_result_code(Result)==200;
    _ -> false
  end.

http_content_length(Result) ->
  Headers = http_headers(Result),
  proplists:get_value("content-length",Headers).

http_content_type(Result) ->
  Headers = http_headers(Result),
  proplists:get_value("content-type",Headers).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Probably non-ok responses can have a body too...
response_has_body(Result) ->
  case http_result_type(Result) of
    ok ->
      ContentLength = http_content_length(Result),
      if
        ContentLength=/=undefined ->
          ContLen = list_to_integer(ContentLength),
          ContLen>0;
        true ->
          false
      end;
    _ -> false
  end.

response_has_json_body(Result) ->
  case response_has_body(Result) of
    true when is_list(Result) -> string:str(http_content_type(Result), "application/json") >= 0;
    false -> false;
    _ ->
      %% error_messages:no_content_type(),
      true
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init_table(PrivateModule,Links) ->
  case ets:info(js_links_machine_data) of
    undefined ->
      ok;
    _ ->
      [{pid,Pid}] = ets:lookup(js_links_machine_data,pid),
      exit(Pid,kill),
      ets:delete(js_links_machine_data)
  end,
  spawn
    (fun () ->
         ets:new(js_links_machine_data,[named_table,public]),
         ets:insert(js_links_machine_data,{pid,self()}),
         wait_forever()
     end),
  wait_until_stable(),
  ets:insert(js_links_machine_data,{private_module,PrivateModule}),
  ets:insert(js_links_machine_data,{initial_links,Links}).

wait_until_stable() ->
  case ets:info(js_links_machine_data) of
    L when is_list(L) ->
      ok;
    _ ->
      wait_until_stable()
  end.

wait_forever() ->
  receive _ -> wait_forever() end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

prop_ok() ->
  ?FORALL
     (Cmds, noshrink(eqc_dynamic_cluster:dynamic_commands(?MODULE)),
      ?CHECK_COMMANDS
         ({H, DS, Res},
          ?MODULE,
          Cmds,
          begin
            %%io:format("Res size is ~p~n",[erts_debug:size(Res)]),
            %%io:format("DS size is ~p~n",[erts_debug:size(DS)]),
            %%io:format("length(H)=~p~n",[length(H)]),
            %%[{P1,P2,P3}|_] = lists:reverse(H),
            %%io:format("P1(1).size=~p~n",[erts_debug:size(P1)]),
            %%io:format("P2(1).size=~p~n",[erts_debug:size(P2)]),
            %%io:format("P3(1).size=~p~n",[erts_debug:size(P3)]),
            %%io:format("P1=~p~n",[P1]),
            %%io:format("P2=~p~n",[P2]),
            %%io:format("P3=~p~n",[P3]),
            %%io:format("H size is ~p~n",[erts_debug:size(H)]),
            %%io:format("H=~p~nDS=~p~n",[H,DS]),
            if
              Res == ok ->
                true;
              true ->
                print_counterexample(Cmds,H,DS,Res),
                false
            end
          end)).

print_counterexample(Cmds,H,_DS,Reason) ->
  io:format("~nTest failed with reason ~p~n",[Reason]),
  {FailingCommandSequence,_} = lists:split(length(H)+1,Cmds),
  ReturnValues =
    case Reason of
      {exception,_} ->
        (lists:map(fun (Item) -> Item#eqc_statem_history.result end, H))++[Reason];
      _ ->
        (lists:map(fun (Item) -> Item#eqc_statem_history.result end, H))
    end,
  io:format("~nCommand sequence:~n"),
  io:format("---------------~n~n"),
  print_commands(lists:zip(tl(FailingCommandSequence),ReturnValues)),
  io:format("~n~n").

print_commands([]) ->
  ok;
print_commands([{_Call={call,_,start,_,_},_Result}|Rest]) ->
  print_commands(Rest);
print_commands([{Call={call,_,link,Args,_},Result}|Rest]) ->
  Title = call_link_title(Call),
  TitleString =
    if
      Title==undefined ->
        "Link ";
      true ->
        io_lib:format("Link ~p ",[Title])
    end,
  ResultString =
    case http_result_type(Result) of
      {error,Error} ->
        io_lib:format(" ->~n    error ~p~n",[Error]);
      ok ->
        ResponseCode = http_result_code(Result),
        case response_has_body(Result) of
          true ->
            Body =
              case has_ets_body(Result) of
                true -> "<<abstracted_body>>";
                false -> http_body(Result)
              end,
            io_lib:format
              (" ->~n    ~p with body:~n~s",
               [ResponseCode,jsg_json:pretty_json(Body)]);
          false ->
            io_lib:format
              (" ->~n     ~p",
               [ResponseCode])
        end
    end,
  io:format
    ("~saccess ~s~s~n~n",
     [TitleString,format_http_call(Args),ResultString]),
  print_commands(Rest);
print_commands([{Call,_Result}|_Rest]) ->
  io:format("seeing Call ~p~n",[Call]),
  throw(bad).

test() ->
  Validator = get_option(validator),
  Validator:start_validator(),
  jsg_store:put(stats,[]),
  case eqc:quickcheck(eqc:on_output(fun eqc_printer/2,prop_ok())) of
    false ->
      io:format("~n~n***FAILED~n");
    true ->
      io:format("~n~nPASSED~n",[])
  end,
  print_stats().

%% @doc Punto de entrada a la librería para ejecutar los tests con la
%% ejecución del test de jsongen.
%%
%% @param Files Lista de ficheros que
%% formarán el conjunto de links iniciales (links estáticos).  Los
%% ficheros deberán estar en el path para que puedan leerse.
%% @end
-spec run_statem(Files :: list(filename())) -> ok.
run_statem(Files) ->
  run_statem(void,Files).

%% @doc Ejecución del test de jsongen pero sobreescribiendo las
%% funciones de Quickcheck con el módulo indicado.
%%
%% Si hay alguna función en el `PrivateModule' especificado que sobreescriba la
%% función de Quickcheck para la máquina de estados, se ejecutará
%% dicha función en lugar de la implementada por defecto en JSONgen
%%
%% @param PrivateModule módulo erlang (sin terminación .erl)
%% implementado por el usuario que contiene una o más funciones que
%% sustituirán a las que usa Quickcheck para la máquina de estados.
%% @end
-spec run_statem(PrivateModule :: atom(), Files :: list(filename())) -> ok.
run_statem(PrivateModule,Files) ->
  run_statem(PrivateModule,Files,[]).


%% @doc Ejecución de los tests de jsongen con módulo y opciones.
%% En cso de que no se quiera usar ningún módulo auxiliar pero sí las opciones, se deberá indicar
%% que el módulo es `void'.
%%
%% @param Options lista de tuplas {Opción,Valor}.
%% @end
%% @spec run_statem(PrivateModule :: atom()
%%                  , Files :: list(filename())
%%                  , Options :: list(option())) -> ok
%% where
%%       option() =   {cookies, boolean()}
%%                  | {user, string()}
%%                  | {password, string()}
%%                  | {timeout, integer()}
%%                  | {simulation_mode, boolean()}
%%                  | {show_http_timing, boolean()}
%%                  | {show_http_result, boolean()}
%%                  | {show_uri, boolean()}
%%                  | {validator, atom()}
%% @end
-spec run_statem(PrivateModule :: atom(), Files :: list(filename()), Options :: list()) -> ok.
run_statem(PrivateModule,Files,Options) ->
  if
    is_list(Files) ->
      lists:foreach
        (fun (File) ->
             if
               is_list(File) -> ok;
               true ->
                 io:format
                   ("~n*** Error: the argument ~p (files) to run_statem "++
                      " is not contain a list of files.~n",
                    [Files]),
                 throw(badarg)
             end
         end, Files);
    true ->
      io:format
        ("~n*** Error: the argument ~p (files) to run_statem "++
           " is not contain a list of files.~n",
         [Files]),
      throw(badarg)
  end,
  inets:start(),
  case proplists:get_value(cookies,Options) of
    true ->
      ok = httpc:set_options([{cookies,enabled}]);
    _ ->
      ok
  end,
  case collect_links(Files) of
    [] ->
      io:format
        ("*** Error: no independent links could be found among the files ~p~n",
         [Files]),
      throw(bad);
    Links ->
      js_links_machine:init_table(PrivateModule,Links)
  end,
  check_and_set_options(Options),
  js_links_machine:test().
%% @end

print_stats() ->
  {ok,Stats} = jsg_store:get(stats),
  TotalCalls =
    lists:foldl(fun ({_,N},Acc) -> N+Acc end, 0, Stats),
  SortedStats =
    lists:sort(fun ({_,N},{_,M}) -> N>=M end, Stats),
  io:format("~nLink statistics:~n-------------------~n"),
  lists:foreach
    (fun ({Name,NumCalls}) ->
         Percentage = (NumCalls/TotalCalls)*100,
         io:format("~p: ~p calls (~p%)~n",[Name,NumCalls,Percentage])
     end, SortedStats).

%% To make eqc not print the horrible counterexample
eqc_printer(Format,String) ->
  case Format of
    "~p~n" -> ok;
    _ -> io:format(Format,String)
  end.

check_and_set_options(Options) ->
  ParsedOptions =
    lists:map
      (fun (Option) ->
           {Prop,Value} = ParsedOption =
             case Option of
               {Atom,Val} when is_atom(Atom) -> {Atom,Val};
               Atom when is_atom(Atom) -> {Atom,true}
             end,
           case Prop of
             cookies when is_boolean(Value) ->
               if
                 Value ->
                   ok = httpc:set_options([{cookies,enabled}]);
                 true ->
                   ok
               end,
               ParsedOption;
             user when is_list(Value) -> ParsedOption;
             password when is_list(Value) -> ParsedOption;
             timeout when is_integer(Value),Value>0 -> ParsedOption;
             simulation_mode when is_boolean(Value) -> ParsedOption;
             show_http_timing when is_boolean(Value) -> ParsedOption;
             show_http_result when is_boolean(Value) -> ParsedOption;
             show_uri when is_boolean(Value) -> ParsedOption;
             validator when is_atom(Value) -> ParsedOption;
             Other ->
               io:format
                 ("*** Error: option ~p not recognized~n",
                  [Other]),
               throw(bad)
           end
       end, Options),
  NewParsedOptions1 =
    case proplists:get_value(validator,ParsedOptions) of
      undefined -> [{validator,java_validator}|ParsedOptions];
      _ -> ParsedOptions
    end,
  NewParsedOptions2 =
    case proplists:get_value(timeout,NewParsedOptions1) of
      undefined -> [{timeout,1500}|NewParsedOptions1];
      _ -> NewParsedOptions1
    end,
  ets:insert(js_links_machine_data,{options,NewParsedOptions2}).

get_option(Atom) when is_atom(Atom) ->
  [{_,Options}] = ets:lookup(js_links_machine_data,options),
  proplists:get_value(Atom,Options,false).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

call_link_title(Call) ->
  jsg_links:link_title(call_link(Call)).

call_link({call,_,_,[Link,_],_}) ->
  Link;
call_link(CallPropList) ->
  {link, proplists:get_value(link, CallPropList)}.

args_link_title(Call) ->
  jsg_links:link_title(args_link(Call)).

args_link([Link,_]) ->
  Link.

json_call_body([_,{_,_,BodyArg,_}]) ->
  case BodyArg of
    {ok,Body} -> Body
  end.

get_json_body(Result) ->
  case response_has_json_body(Result) of
    true -> mochijson2:decode(http_body(Result))
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

collect_links(Files) ->
  lists:flatmap(fun collect_links_from_file/1, Files).

collect_links_from_file(File) ->
  FileSchema = {struct,[{<<"$ref">>,list_to_binary(File)}]},
  lists:map
    (fun (Link={link,Props}) ->
         {link,[{type,static},
                {calculated_href,jsg_links:link_href(Link)}|Props]}
     end, collect_schema_links(FileSchema,false)).

collect_schema_links(RawSchema, DependsOnObject) ->
  Schema = jsg_links:get_schema(RawSchema),
  %% Find all schemas, and retrieve links
  case jsg_jsonschema:links(Schema) of
    undefined ->
      [];
    Links when is_list(Links) ->
      lists:foldl
        (fun ({N,Link},Ls) ->
             Dependency = depends_on_object_properties(Link),
             Headers = jsg_links:collect_headers(Link),
             if
               Dependency==DependsOnObject ->
                 [{link,[{link,N},{schema,RawSchema},{headers,Headers}]}|Ls];
               true ->
                 Ls
             end
         end, [], lists:zip(lists:seq(1,length(Links)),Links))
  end.

depends_on_object_properties(Link) ->
  case jsg_jsonschema:propertyValue(Link,"href") of
    Value when is_binary(Value) ->
      Href = binary_to_list(Value),
      Template = uri_template:parse(Href),
      (jsg_jsonschema:propertyValue(Link,"isRelative")==true) orelse
                                                                (lists:any(fun ({var, _, _}) -> true;
                                                                               (_) -> false
                                                                           end, Template))
  end.
