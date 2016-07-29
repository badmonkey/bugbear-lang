
-module(preprocessor).

-export([ new/2, new/3, define_macro/4
        , file/1, file/2, file/3, process/2
        , format/1, split_token_expr/1
        , get_filename/1, get_module/1 ]).


%%%%% ------------------------------------------------------- %%%%%


-type macro_name() :: string() | {string(), type:cardinal()}.
-type macro_params() :: constant | [ atom() ].
-type macro_args() :: constant | [ type:tokens() ].
-type macro_value() :: type:tokens() | fun( ( string(), type:location(), macro_args() ) -> type:tokens() ).

-type macros_type() :: #{ macro_name() => macro_value() }.

-type directive_cb(S) :: fun( ( atom(), type:location(), macro_args(), S ) -> {ok, S} | {replace, type:tokens(), S} ).


-record(state,
       { scanner        = fun erl_scan:string/2 	:: type:scanner()
       , filestack      = []                    	:: [string()]
       , module         = undefined                	:: atom()
       , macros         = #{}                   	:: macros_type()
       , resolver       = fun type:identity/1   	:: fun( ( string() ) -> string() )
       , directives     = #{}                   	:: #{ atom() => directive_cb(#state{}) }
       , split_expr     = fun split_token_expr/1	:: fun( ( type:tokens() ) -> [type:tokens()] )
       , options        = #{}                   	:: #{ atom() => term() }
       }).
-opaque state() :: #state{}.
       
-export_type([ state/0 ]).       

       
-define(TOKEN_CHUNK, 'beamtools$CHUNK').
-define(TOKEN_DIRECTIVE, 'beamtools$DIRECTIVE').
-define(TOKEN_STASH, 'beamtools$STASH').
-define(TOKEN_ARG, 'beamtool$arg').
       
-define(PATTERN_DASH, {'-',_}).    
-define(PATTERN_QMARK, {'?',_}).
-define(PATTERN_LBRACKET, {'(',_}).
-define(PATTERN_RBRACKET, {')',_}).
-define(PATTERN_COMMA, {',',_}).
-define(PATTERN_DOT, {dot,_}).
-define(PATTERN_ATOM(X), {atom,_,X}).
-define(PATTERN_VAR(X), {var,_,X}).
-define(PATTERN_LCURL, {'{',_}).
-define(PATTERN_RCURL, {'}',_}).
-define(PATTERN_LSQR, {'[',_}).
-define(PATTERN_RSQR, {']',_}).
       

%%%%% ------------------------------------------------------- %%%%%

%
% scanner       :: type:scanner()
% split_expr
% directives    :: [atom()]
% defines       :: [{string(), macro_params(), macro_value()}]
%

default_directive(_Name, _Loc, _Args, State) ->
    {ok, State}.
    

new(undefined, #{} = Opts) ->
    new("<unknown>", mk_module_name(), Opts);

new(FileName, #{} = Opts) ->
    Module = filename:basename(FileName, filename:extension(FileName)),
    new(FileName, Module, Opts).
   
    
new(FileName, Module, #{} = Opts)
        when is_list(FileName), is_atom(Module)  ->    
    S0 = #state{ filestack = [FileName], module = Module },
    
    S1 = miscutils:if_valid_then_update( scanner, Opts
                                       , fun(X) -> is_function(X, 2) end
                                       , #state.scanner, S0),
                                       
    S2 = define_macros([ {"FILE", constant, tokens:from_term(FileName)}
                       , {"MODULE", constant, tokens:from_term(Module)}
                       , {"MODULE_STRING", constant, tokens:from_term(erlang:atom_to_list(Module))}
                       , {"LINE", constant, fun macro_line_func/3}
                       , {"MACHINE", constant, tokens:from_term('BEAM')}
                       | maps:get(defines, Opts, [])
                       ], S1),
                       
    S2#state{
        directives = #{ module  => fun default_directive/4
                      , comment => fun default_directive/4
                      }
    }.

    
%%%%% ------------------------------------------------------- %%%%%


define_macros([], State) ->
    State;
    
define_macros([{N, P, V} | Tail], State) ->
    NewState = define_macro(N, P, V, State),
    define_macros(Tail, NewState).


-spec define_macro( string(), macro_params(), macro_value(), #state{} ) -> #state{}.
    
define_macro(Name, Params, Value, #state{ macros = Macros } = State) ->
    State.
    

%%%%% ------------------------------------------------------- %%%%%


file(FileName) -> file(FileName, #{}).

file(FileName, #{} = Opts) ->  
    Module = filename:basename(FileName, filename:extension(FileName)),
    file(FileName, Module, Opts);

file(FileName, #state{} = State) ->
    S2 = define_macro("FILE", constant, tokens:from_term(FileName), State),
    process_file( push_filename(FileName, S2) ).
    
    
file(FileName, Module, #{} = Opts) ->
    process_file( new(FileName, Module, Opts) ).
    
    
process_file(#state{ scanner = Scanner } = State) ->
    {ok, FileContents} = file:read_file( get_filename(State) ),
    Data = binary_to_list(FileContents),
    Output = Scanner(Data, {1,1}),
    process(Output, State).
        
    
%%%%% ------------------------------------------------------- %%%%%


-spec process( type:token_return(), #state{} ) -> type:token_return().

process({error, _ErrorInfo, _} = Error, _State) ->
    Error;
    
process({ok, Tokens, EndLoc}, #state{} = State) ->
    Stream = tokstream:new(?TOKEN_CHUNK, State),
    FileAttr = tokens:file_attribute(get_filename(State), {1,1}),
    
    Filtered = filter_tokens(Tokens, tokstream:push_token(Stream, FileAttr)),
    
    % Parse
    % unchunk

    {ok, Filtered, EndLoc}.


%%%%% ------------------------------------------------------- %%%%%


-spec format( type:tokens() ) -> string().
format(X) ->
    ok.
    

%%%%% ------------------------------------------------------- %%%%%


% scan list of tokens for interesting tokens (hiding the rest in fake 'chunk' tokens).

filter_tokens([], Stream) ->
    tokstream:final(Stream);

filter_tokens([?PATTERN_QMARK = TokQMark, ?PATTERN_ATOM(_) = TokName | Rest], Stream) ->
    {RestInput, Stream2} = scan_macro_use(Rest, tokstream:push_many_tokens(Stream, [TokQMark, TokName])),
    filter_tokens(RestInput, Stream2);
    
filter_tokens([?PATTERN_QMARK = TokQMark, ?PATTERN_VAR(_) = TokName | Rest], Stream) ->
    {RestInput, Stream2} = scan_macro_use(Rest, tokstream:push_many_tokens(Stream, [TokQMark, TokName])),
    filter_tokens(RestInput, Stream2);

filter_tokens([?PATTERN_DASH = TokDash, ?PATTERN_ATOM(Directive) = TokName | Rest], Stream) ->
    {RestInput, Stream2} =  case lists:member(Directive, directives()) of
                                true    -> scan_directive(Directive, Rest, tokstream:push_many_tokens(Stream, [TokDash, TokName]))
                            ;   false   ->
                                    State = tokstream:get_userdata(Stream),
                                    case maps:is_key(Directive, State#state.directives) of
                                        true    ->
                                            NewToken = tokens:make_embed(?TOKEN_DIRECTIVE, TokName),
                                            scan_directive(custom, Rest, tokstream:push_many_tokens(Stream, [TokDash, NewToken]))
                                    ;   false   ->
                                            chunk_tokens(Rest, tokstream:push_to_chunk(Stream, [TokDash, TokName]))
                                    end
                            end,
    filter_tokens(RestInput, Stream2);

filter_tokens(Input, Stream) ->
    {RestInput, Stream2} = chunk_tokens(Input, Stream),
    filter_tokens(RestInput, Stream2).


%%%%% ------------------------------------------------------- %%%%%


scan_macro_use([], Stream) ->
    {[], Stream};
    
scan_macro_use([?PATTERN_LBRACKET = TokLeft | Rest], Stream) ->
    {RestInput, Stream2} = chunk_exprs(Rest, tokstream:push_token(Stream, TokLeft), 0),
    case RestInput of
        [?PATTERN_RBRACKET = TokRight | Rest2] ->
            {Rest2, tokstream:push_token(Stream2, TokRight)}
            
    ;   _               ->
            chunk_tokens(RestInput, Stream2)
    end;

scan_macro_use(Input, Stream) ->
    {Input, Stream}.


%%%%% ------------------------------------------------------- %%%%%


scan_directive(_, [], Stream) ->
    {[], Stream};
    
    
scan_directive('else', [?PATTERN_DOT = TokDot | Rest], Stream) ->
    {Rest, tokstream:push_token(Stream, TokDot)};
    
scan_directive('endif', [?PATTERN_DOT = TokDot | Rest], Stream) ->
    {Rest, tokstream:push_token(Stream, TokDot)};
    
    
scan_directive('undef', Input, Stream) ->
    match_macro_name(Input, Stream);
    
scan_directive('ifdef', Input, Stream) ->
    match_macro_name(Input, Stream);
    
scan_directive('ifndef', Input, Stream) ->
    match_macro_name(Input, Stream);


scan_directive('define', Input, Stream) ->
    chunk_tokens(Input, Stream);


scan_directive(custom, Input, Stream) ->
    {RestInput, Stream2} = scan_macro_use(Input, Stream),
    case RestInput of
        [?PATTERN_DOT = TokDot | Rest2] ->
            {Rest2, tokstream:push_token(Stream2, TokDot)}
            
    ;   _               ->
            chunk_tokens(RestInput, Stream2)
    end;
    
        
scan_directive(_, Input, Stream) ->
    chunk_tokens(Input, Stream).     % likely force an error in the next stage
    
    
match_macro_name([?PATTERN_LBRACKET = TokLeft, ?PATTERN_ATOM(_) = TokName, ?PATTERN_RBRACKET = TokRight, ?PATTERN_DOT = TokDot | Rest], Stream) ->
    {Rest, tokstream:push_many_tokens(Stream, [TokLeft, TokName, TokRight, TokDot])};
    
match_macro_name([?PATTERN_LBRACKET = TokLeft, ?PATTERN_VAR(_) = TokName, ?PATTERN_RBRACKET = TokRight, ?PATTERN_DOT = TokDot | Rest], Stream) ->
    {Rest, tokstream:push_many_tokens(Stream, [TokLeft, TokName, TokRight, TokDot])};
    
match_macro_name(Input, Stream) ->
    chunk_tokens(Input, Stream).    %% @todo not sure, force in parser?


%%%%% ------------------------------------------------------- %%%%%


chunk_tokens([], Stream) ->
    {[], tokstream:end_chunk(Stream)};
    
chunk_tokens([?PATTERN_QMARK, ?PATTERN_ATOM(_) | _Rest] = Input, Stream) ->
    {Input, tokstream:end_chunk(Stream)};
    
chunk_tokens([?PATTERN_QMARK, ?PATTERN_VAR(_) | _Rest] = Input, Stream) ->
    {Input, tokstream:end_chunk(Stream)};
    
chunk_tokens([?PATTERN_DASH, ?PATTERN_ATOM(_) | _Rest] = Input, Stream) ->
    {Input, Stream};

    
chunk_tokens([Hd | Rest], Stream) ->
    chunk_tokens(Rest, tokstream:push_to_chunk(Stream, Hd)).
    

%%%%% ------------------------------------------------------- %%%%%


chunk_exprs([], Stream, 0) ->
    {[], tokstream:end_chunk(Stream) };

chunk_exprs([], Stream, _Depth) ->
    {[], tokstream:error(Stream)};  % @todo error message


chunk_exprs([?PATTERN_LBRACKET = TokLeft | Rest], Stream, Depth) ->
    chunk_exprs(Rest, tokstream:push_to_chunk(Stream, TokLeft), Depth + 1);

chunk_exprs([?PATTERN_RBRACKET | _Rest] = Input, Stream, 0) ->
    {Input, tokstream:end_chunk(Stream) };

chunk_exprs([?PATTERN_RBRACKET = TokRight | Rest], Stream, Depth) ->
    chunk_exprs(Rest, tokstream:push_to_chunk(Stream, TokRight), Depth - 1);


chunk_exprs([?PATTERN_QMARK = TokQMark, ?PATTERN_ATOM(_) = TokName | Rest], Stream, Depth) ->
    {RestInput, Stream2} = scan_macro_use(Rest, tokstream:push_many_tokens(Stream, [TokQMark, TokName])),
    chunk_exprs(RestInput, Stream2, Depth);
    
chunk_exprs([?PATTERN_QMARK = TokQMark, ?PATTERN_VAR(_) = TokName | Rest], Stream, Depth) ->
    {RestInput, Stream2} = scan_macro_use(Rest, tokstream:push_many_tokens(Stream, [TokQMark, TokName])),
    chunk_exprs(RestInput, Stream2, Depth);

chunk_exprs([?PATTERN_QMARK = TokQMark, ?PATTERN_QMARK = TokQMark2, ?PATTERN_VAR(_) = TokName | Rest], Stream, Depth) ->
    chunk_exprs(Rest, tokstream:push_many_tokens(Stream, [TokQMark, TokQMark2, TokName]), Depth);


chunk_exprs([Hd | Rest], Stream, Depth) ->
    chunk_exprs(Rest, tokstream:push_to_chunk(Stream, Hd), Depth).


    

%%%%% ------------------------------------------------------- %%%%%


directives() ->
    [include, include_lib, define, ifdef, ifndef, undef, else, endif].


%%%%% ------------------------------------------------------- %%%%%    


-spec macro_line_func( string(), type:location(), macro_args() ) -> type:tokens().

macro_line_func(_, {L, _}, constant)    -> tokens:from_term(L);
macro_line_func(_, L, constant)         -> tokens:from_term(L).


%%%%% ------------------------------------------------------- %%%%%    


get_filename(#state{ filestack = [] }) -> [];
get_filename(#state{ filestack = [H | _] }) -> H.

get_module(#state{ module = M }) -> M.


push_filename(FileName, #state{ filestack = FS } = S) ->
    S#state{ filestack = [FileName | FS] }.
    
pop_filename(#state{ filestack = [] } = S) -> S;
pop_filename(#state{ filestack = [_ | T] } = S) ->
    S#state{ filestack = T }.
    

%%%%% ------------------------------------------------------- %%%%%    


mk_module_name() ->
    erlang:string_to_atom( io_lib:format("unamed-~i", [erlang:unique_integer([positive])]) ).


%%%%% ------------------------------------------------------- %%%%%    


-spec split_token_expr( type:tokens() ) -> [type:tokens()].

split_token_expr(Tokens) ->
	Stream = split_exprs(Tokens, tokstream:new(?TOKEN_CHUNK), {0,0,0}),
	SplitTokens = tokstream:final(Stream),
	[ tokens:get_embed_data(?TOKEN_CHUNK, X) || X <- SplitTokens ].


split_exprs([], Stream, {0, 0, 0}) ->
    tokstream:end_chunk(Stream);

split_exprs([], Stream, _Depths) ->
    tokstream:error(Stream);  % @todo error message


split_exprs([?PATTERN_LBRACKET = TokLeft | Rest], Stream, {Bra, Curl, Sqr}) ->
    split_exprs(Rest, tokstream:push_to_chunk(Stream, TokLeft), {Bra + 1, Curl, Sqr});

split_exprs([?PATTERN_LCURL = TokLeft | Rest], Stream, {Bra, Curl, Sqr}) ->
    split_exprs(Rest, tokstream:push_to_chunk(Stream, TokLeft), {Bra, Curl + 1, Sqr});

split_exprs([?PATTERN_LSQR = TokLeft | Rest], Stream, {Bra, Curl, Sqr}) ->
    split_exprs(Rest, tokstream:push_to_chunk(Stream, TokLeft), {Bra , Curl, Sqr + 1});


split_exprs([?PATTERN_RBRACKET | _Rest], Stream, {0, _, _}) ->
	tokstream:error(Stream); 	% @todo another error message

split_exprs([?PATTERN_RBRACKET = TokRight | Rest], Stream, {Bra, Curl, Sqr}) ->
    split_exprs(Rest, tokstream:push_to_chunk(Stream, TokRight), {Bra - 1, Curl, Sqr});

split_exprs([?PATTERN_RCURL | _Rest], Stream, {_, 0, _}) ->
	tokstream:error(Stream); 	% @todo another error message

split_exprs([?PATTERN_RCURL = TokRight | Rest], Stream, {Bra, Curl, Sqr}) ->
    split_exprs(Rest, tokstream:push_to_chunk(Stream, TokRight), {Bra, Curl - 1, Sqr});

split_exprs([?PATTERN_RSQR | _Rest], Stream, {_, _, 0}) ->
	tokstream:error(Stream); 	% @todo another error message

split_exprs([?PATTERN_RSQR = TokRight | Rest], Stream, {Bra, Curl, Sqr}) ->
    split_exprs(Rest, tokstream:push_to_chunk(Stream, TokRight), {Bra, Curl, Sqr - 1});


split_exprs([?PATTERN_COMMA | Rest], Stream, {0, 0, 0} = Depth) ->
	split_exprs(Rest, tokstream:end_chunk(Stream), Depth);


split_exprs([Hd | Rest], Stream, Depths) ->
    split_exprs(Rest, tokstream:push_to_chunk(Stream, Hd), Depths).


