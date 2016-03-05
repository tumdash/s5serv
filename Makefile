SRC_FLS = sin s5serv_sup
CC = erlc
INC_DIR = include
BIN_DIR = bin/
SRC_DIR = src/
BIN_FLS = $(addsuffix .beam, $(SRC_FLS))
OPT = -o ebin -I$(INC_DIR)

%.beam : $(SRC_DIR)%.erl
	$(CC) $(OPT) $^ 

run : $(BIN_FLS)
	@echo Starting shell
	erl -pa ebin
