
-define(S5_IN_PORT, 1080).
-define(VER, 5).

%SOCK CMD requests
-define(CONNECT, 1).
-define(BIND, 2).
-define(UDP_ACCOSSIATE, 3).

-record(sin_state, {
    listener_socket,
    acceptor_socket,
    target,
    state}).
