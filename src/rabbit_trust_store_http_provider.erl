-module(rabbit_trust_store_http_provider).

-include_lib("public_key/include/public_key.hrl").

-behaviour(rabbit_trust_store_certificate_provider).

-define(PROFILE, ?MODULE).

-export([list_certs/1, list_certs/2, load_cert/3]).

-record(http_state,{
    url :: string(),
    http_options :: list(),
    headers :: httpc:headers()
}).

list_certs(Config) ->
    init(Config),
    State = init_state(Config),
    list_certs(Config, State).

list_certs(_, #http_state{url = Url,
                          http_options = HttpOptions,
                          headers = Headers} = State) ->
    Res = httpc:request(get, {Url, Headers}, HttpOptions, [{body_format, binary}], ?PROFILE),
    case Res of
        {ok, {{_, 200, _}, RespHeaders, Body}} ->
            Certs = decode_cert_list(Body),
            NewState = new_state(RespHeaders, State),
            {ok, Certs, NewState};
        {ok, {{_,304, _}, _, _}}  -> no_change;
        {ok, {{_,Code,_}, _, Body}} -> {error, {http_error, Code, Body}};
        {error, Reason} -> {error, Reason}
    end.

load_cert(_, Attributes, Config) ->
    CertPath = proplists:get_value(path, Attributes),
    #http_state{url = BaseUrl,
                http_options = HttpOptions,
                headers = Headers} = init_state(Config),
    Url = join_url(BaseUrl, CertPath),
    Res = httpc:request(get,
                        {Url, Headers},
                        HttpOptions,
                        [{body_format, binary}, {full_result, false}],
                        ?PROFILE),
    case Res of
        {ok, {200, Body}} ->
            [{'Certificate', Cert, not_encrypted}] = public_key:pem_decode(Body),
            {ok, Cert};
        {ok, {Code, Body}} -> {error, {http_error, Code, Body}};
        {error, Reason}    -> {error, Reason}
    end.

join_url(BaseUrl, CertPath)  ->
    string:strip(rabbit_data_coercion:to_list(BaseUrl), right, $/)
    ++ "/" ++
    string:strip(rabbit_data_coercion:to_list(CertPath), left, $/).

init(Config) ->
    inets:start(httpc, [{profile, ?PROFILE}]),
    ssl:start(),
    Options = proplists:get_value(proxy_options, Config, []),
    httpc:set_options(Options, ?PROFILE).

init_state(Config) ->
    Url = proplists:get_value(url, Config),
    Headers = proplists:get_value(http_headers, Config, []),
    HttpOptions = case proplists:get_value(ssl_options, Config) of
        undefined -> [];
        SslOpts   -> [{ssl, SslOpts}]
    end,
    #http_state{url = Url, http_options = HttpOptions, headers = Headers}.

decode_cert_list(Body) ->
    Struct = rabbit_json:decode(Body),
    #{<<"certificates">> := Certs} = Struct,
    lists:map(
        fun(Cert) ->
            Path = maps:get(<<"path">>, Cert),
            CertId = maps:get(<<"id">>, Cert),
            {CertId, [{path, Path}]}
        end,
        Certs).

new_state(RespHeaders, #http_state{headers = Headers0} = State) ->
    LastModified0 = proplists:get_value("last-modified", RespHeaders),
    LastModified1 = proplists:get_value("Last-Modified", RespHeaders, LastModified0),
    case LastModified1 of
        undefined -> State;
        Value     ->
            Headers1 = lists:ukeysort(1, Headers0),
            NewHeaders = lists:ukeymerge(1, [{"If-Modified-Since", Value}], Headers1),
            State#http_state{headers = NewHeaders}
    end.
