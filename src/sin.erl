-module(sin).
-behaviour(gen_server).
-define(S5_SERVER, ?MODULE).
-include("s5_def.hrl").

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------
-export([start_link/1, start_link/0]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
start_link(Socket) ->
    gen_server:start_link({local, ?S5_SERVER}, ?MODULE, Socket, []).

start_link() ->
    {ok, L} = gen_tcp:listen(1080, [{active, true}]),
    gen_server:start_link({local, ?S5_SERVER}, ?MODULE, L, []).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------
init(LSocket) ->
    %accept Listen socket is blocking,
    %so we would cast that to server inside
    gen_server:cast(self(), accept),
    State = make_state(LSocket, null, null, listening),
    {ok, State}.

%never need here
handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(accept, State=#sin_state{listener_socket=Sock, acceptor_socket=null}) ->
    {ok, ASocket} = gen_tcp:accept(Sock),
    s5serv_sup:start_socket(),
    NewState = make_state(State#sin_state.listener_socket, ASocket, null, accepted),
    {noreply, NewState}.

%========================================================
% The client connects to the server, and sends a version
% identifier/method selection message:
% +----+----------+----------+
% |VER | NMETHODS | METHODS  |
% +----+----------+----------+
% | 1  |    1     | 1 to 255 |
% +----+----------+----------+
%========================================================
handle_info({tcp, Sock, <<?VER, Rest/binary>>}, State=#sin_state{acceptor_socket=Sock, state=accepted}) ->
    io:format("~nReceived SOCKS5 Request ~p in ~p", [Rest, State#sin_state.state]),
    
    %server should pick up a method based on available by client
    ServerResponse = make_s5_reply(method, Rest),
    ServerResponseL = binary:bin_to_list(ServerResponse),
    io:format("~n...ServerResponse: ~p", [lists:sublist(ServerResponseL, 20)]),

    %and send back selected method
    gen_tcp:send(Sock, ServerResponseL), 
    
    NewState = make_state(State#sin_state.listener_socket, State#sin_state.acceptor_socket, null, method_taken),
    {noreply, NewState, 1000};

%S5serv receives sock5 request
%   The SOCKS request is formed as follows:
%+----+-----+-------+------+----------+----------+
%|VER | CMD |  RSV  | ATYP | DST.ADDR | DST.PORT |
%+----+-----+-------+------+----------+----------+
%| 1  |  1  | X'00' |  1   | Variable |    2     |
%+----+-----+-------+------+----------+----------+
%=================================================
handle_info({tcp, Sock, <<?VER, ?CONNECT, 0, Rest/binary>>}, State=#sin_state{acceptor_socket=Sock, state=method_taken}) ->
    io:format("~nReceived SOCKS5 Connect Command ~p in ~p", [Rest, State#sin_state.state]),

    %obtain IP and port where to query in future
    {Peer, Port} = make_target_peer(Rest),
    io:format("~n...Target_peer parsing:~p ~p", [Peer, Port]),

    %obtain peer data to build response
    {ok, PeerData} = inet:peername(Sock),

    %server should respond as per RFC
    ServerResponse = make_s5_reply(succeed, PeerData),
    ServerResponseL = binary:bin_to_list(ServerResponse),
    io:format("~n...ServerResponse: ~p", [lists:sublist(ServerResponseL, 20)]),
    {ok, TargetSock} = gen_tcp:connect(Peer, Port, [binary, {active, true}]),

    Target = {TargetSock, {Peer, Port}},
    gen_tcp:send(Sock, ServerResponseL),

    NewState = make_state(State#sin_state.listener_socket, State#sin_state.acceptor_socket, Target, connected),
    {noreply, NewState, 10000};

handle_info({tcp, Sock, Data}, State=#sin_state{acceptor_socket=Sock, target={TargetSock, {_, _}}, state=connected}) ->
    io:format("~nReceived external request ~p in ~p", [lists:sublist(binary:bin_to_list(Data), 20), State#sin_state.state]),
    ok = gen_tcp:send(TargetSock, binary:bin_to_list(Data)),

%    NewState = make_state(State#sin_state.listener_socket, State#sin_state.acceptor_socket, State#sin_state.target, asked),
    {noreply, State, 1000};

handle_info({tcp, TargetSock, Data}, State=#sin_state{acceptor_socket=Sock, target={TargetSock, {_, _}}, state=connected}) ->
    io:format("~nReceived external response ~p in ~p", [lists:sublist(binary:bin_to_list(Data), 20), State#sin_state.state]),
    ok = gen_tcp:send(Sock, Data),
    {noreply, State, 10000};

handle_info({tcp, _Sock, Data}, State=#sin_state{}) ->
    io:format("~nReceived response ~p in ~p", [Data, State#sin_state.state]),
    {noreply, State};

handle_info({tcp_closed, Sock}, State=#sin_state{acceptor_socket=Sock}) ->
    io:format("~nReceived tcp_closed_by_client in ~p", [State#sin_state.state]),
    gen_server:cast(self(), accept),
    NewState = make_state(State#sin_state.listener_socket, null, null, listening),
    {noreply, NewState};

handle_info({tcp_closed, TargetSock}, State=#sin_state{acceptor_socket=Sock, target={TargetSock, {_, _}}}) ->
    io:format("~nReceived tcp_closed_by_external in ~p", [State#sin_state.state]),
    ok = gen_tcp:close(TargetSock),
    ok = gen_tcp:close(Sock),
    gen_server:cast(self(), accept),
    NewState = make_state(State#sin_state.listener_socket, null, null, listening),
    {noreply, NewState};

handle_info({tcp_closed, Sock}, State=#sin_state{}) ->
    %obtain peer data to build response
    {ok, {Peer, Port}} = inet:peername(Sock),
    io:format("~nReceived tcp_closed_by_someone in ~p for ~p (~p:~p)", [State#sin_state.state, Sock, Peer, Port]),
    gen_server:cast(self(), accept),
    NewState = make_state(State#sin_state.listener_socket, null, null, listening),
    {noreply, NewState};

handle_info(timeout, State=#sin_state{acceptor_socket=Sock, target={TargetSock,{_,_}}, state=connected}) ->
    io:format("~nReceived timeout in ~p", [State#sin_state.state]),
    ok = gen_tcp:close(TargetSock),
    ok = gen_tcp:close(Sock),
    gen_server:cast(self(), accept),
    NewState = make_state(State#sin_state.listener_socket, null, null, listening),
    {noreply, NewState};

handle_info(timeout, State) ->
    io:format("~nReceived unexpected timeout in ~p", [State]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------
%========================================================
%  The server selects from one of the methods given in METHODS, and
%  sends a METHOD selection message:
% +----+--------+
% |VER | METHOD |
% +----+--------+
% | 1  |   1    |
% +----+--------+
%========================================================
make_s5_reply(method, BinStr) when is_binary(BinStr) ->
    io:format("~n...Server takes NO AUTHENTICATION"),
    << ?VER, 0 >>;

%=================================================
%The server evaluates the request, and returns a reply formed as follows:
%+----+-----+-------+------+----------+----------+
%|VER | REP |  RSV  | ATYP | BND.ADDR | BND.PORT |
%+----+-----+-------+------+----------+----------+
%| 1  |  1  | X'00' |  1   | Variable |    2     |
%+----+-----+-------+------+----------+----------+
%=================================================
make_s5_reply(succeed, {{Ip1, Ip2, Ip3, Ip4}, Port}) when is_number(Port) ->
    << ?VER, 0, 0, 1, Ip1:8, Ip2:8, Ip3:8, Ip4:8, Port:16 >>.

make_target_peer(BinStr) when is_binary(BinStr) ->
    <<Atype:8/integer, RestBitStr/binary>> = BinStr,
    case Atype of
        3 ->
            <<DomainLen:8/integer, DomainBitStr/binary>> = RestBitStr,
            {DomainName, PortBitStr} = read_domain_string(DomainBitStr, DomainLen),
            <<Port:16/integer>> = PortBitStr;
        _ ->
            DomainName = unknown, Port = unknown
    end,
    {binary:bin_to_list(DomainName), Port}.

read_domain_string(BitStr, Len) when is_binary(BitStr), is_number(Len) ->
%tail-recursion
    {ok, ExtBitStr, RestBitStr} = read_bitstr(BitStr, Len, <<>>),
    {ExtBitStr, RestBitStr}.

read_bitstr(BitStr, 0, ResultStr) -> {ok, ResultStr, BitStr};
read_bitstr(<<>>, _Len, ResultStr) -> {error, ResultStr, <<>>};
read_bitstr(<<Ch:8, Rest/binary>>, Len, ResultStr) ->
%    io:format("~nread_bitstr: ~p ~p ~p", [Ch, Len, ResultStr]),
%    io:format("~nread_bitstr: ~p ~p ~p", [Rest, Len-1, NNN]),
    read_bitstr(Rest, Len-1, <<ResultStr/binary, Ch>>).

acceptor(Listener) ->
    {ok, Socket} = gen_tcp:accept(Listener),
    receive
        {tcp, Socket, Msg} ->
            io:format("~n...Received msg ~p", [Msg]);
        Msg ->
            io:format("~n...Received msg ~p", [Msg])
    end.
        
make_state(ListenSocket, AcceptorSocket, Target, State) ->
    #sin_state{
        listener_socket = ListenSocket,
        acceptor_socket = AcceptorSocket,
        target = Target,
        state = State }.

