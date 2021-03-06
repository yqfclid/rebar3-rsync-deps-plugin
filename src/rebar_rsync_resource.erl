-module(rebar_rsync_resource).

-export([init/2,
         lock/2,
         download/4, 
         %download/3,
         needs_update/2,
         make_vsn/2]).

-export([get_ref/1]).

-define(FAIL, rebar_utils:abort()).
-define(ABORT(Str, Args), rebar_utils:abort(Str, Args)).

-define(CONSOLE(Str, Args), io:format(Str++"~n", Args)).

-define(DEBUG(Str, Args), rebar_log:log(debug, Str, Args)).
-define(INFO(Str, Args), rebar_log:log(info, Str, Args)).
-define(WARN(Str, Args), rebar_log:log(warn, Str, Args)).
-define(ERROR(Str, Args), rebar_log:log(error, Str, Args)).
-define(CRASHDUMP(Str, Args), rebar_log:crashdump(Str, Args)).

-define(FMT(Str, Args), lists:flatten(io_lib:format(Str, Args))).


%% Initialize the custom dep resource plugin
init(Type, _RebarState) ->
    %?INFO("Type: ~p",[Type]),
    Resource = rebar_resource_v2:new(Type, ?MODULE, #{}),
    {ok, Resource}.

lock(AppInfo, _) ->
    check_type_support(),
    lock_(rebar_app_info:dir(AppInfo), rebar_app_info:source(AppInfo)).

lock_(AppDir, {rsync, Url, _}) ->
    lock_(AppDir, {rsync, Url});

lock_(AppDir, {rsync, Url}) ->
    Ref = get_ref(AppDir),
    {rsync, Url, {ref, Ref}}.

get_ref(Dir) -> get_md5sum(Dir).

get_md5sum(Dir) ->
    AbortMsg = lists:flatten(io_lib:format("Locking of rsync dependency failed in ~ts", [Dir])),
    Dir2 = rebar_utils:escape_double_quotes(Dir),
    Cmd = "find " ++ Dir2 ++ " -type f -exec md5sum {} + | sort| md5sum",

    Res =rebar_utils:sh(Cmd, [{use_stdout, false}, {debug_abort_on_error, AbortMsg}]),
    VsnString = case Res of
                    {ok, VsnString0} -> VsnString0;
                    _ -> get_uuid()
                end,
    Ref = string:trim(VsnString, both, "\n -"),
    Ref.

get_uuid() ->
    % from https://github.com/afiskon/erlang-uuid-v4/blob/master/src/uuid.erl
    <<A:32, B:16, C:16, D:16, E:48>> = crypto:strong_rand_bytes(16),
    Str = io_lib:format("~8.16.0b-~4.16.0b-4~3.16.0b-~4.16.0b-~12.16.0b", 
                        [A, B, C band 16#0fff, D band 16#3fff bor 16#8000, E]),
    list_to_binary(Str).

needs_update(AppInfo, _) ->
    check_type_support(),
    needs_update_(rebar_app_info:dir(AppInfo), rebar_app_info:source(AppInfo)).


needs_update_(_Dir, {rsync, _Url, "master"}) -> true;
% we do not separate What: tag, branch,
needs_update_(Dir, {rsync, _Url, {_What, Tag}}) ->
    Current = get_ref(Dir),
    %?DEBUG("Comparing git tag ~ts with ~ts", [Tag, Current]),
    ?INFO("Comparing git tag ~ts with ~ts", [Tag, Current]),
    not (Current =:= Tag).

correct_tmp_dir(TmpDir) ->
     case os:type() of
         {win32, _} ->
             % We run under cygwin. So just convert path using cygpath cmd.
             Cmd = ?FMT("cygpath -u ~s",[TmpDir]),
             %?INFO("Convert Path Cmd:  ~p",[Cmd]),
             Res = rebar_utils:sh(Cmd,[]),
             %?INFO("Convert path Res: ~p",[Res]),
             {ok,TmpDir2} = Res,
             rebar_string:trim(TmpDir2, both, "\n");
         _ -> TmpDir
     end.



download(TmpDir, AppInfo, State, _) ->
    check_type_support(),
    % correct TmpDir under windows.
    % cygwin rsync complains if path start with c:/...
    % Just remove ":" to make Cygwin happy.
    TmpDir2 = correct_tmp_dir(TmpDir),
    %?INFO("TmpDir2: ~p ",[TmpDir2]),
    case download_(TmpDir2, rebar_app_info:source(AppInfo), State) of
        {ok, _} ->
            ok;
        {error, Reason} ->
            ?ERROR("Download error. Reason: ~p",[Reason]),
            {error, Reason};
        Error ->
            ?ERROR("Download error.: ~p",[Error]),
            {error, Error}
    end.


download_(Dir, {rsync, Url, _Tag}, _State) ->
    ok = filelib:ensure_dir(Dir),
    %?INFO("filelib:ensure_dir is ok",[]),
    %?INFO("Url: ~p Dir: ~p",[Url,Dir]),
    Cmd = ?FMT("rsync -az --delete ~s/ ~s", [Url, Dir]),
    %?INFO("Cmd: ~p",[Cmd]),
    Res =rebar_utils:sh(Cmd, []),
    %?INFO("Res: ~p",[Res]),
    Res.


make_vsn(_Dir, _ResourceState) ->
  % for the rsync version is not relevant.
  % return error..
  %{plain, "0.0.1"}.
  {error,"Version not supported for rsync"}.



%% --------- apr ----------------

check_type_support() ->
    case get({is_supported, ?MODULE}) of
        true ->
            ok;
        _ ->
           RsyncRes = rebar_utils:sh("rsync   --version", [{return_on_error, true},{use_stdout, false}]),
           FindRes  = rebar_utils:sh("find    --version", [{return_on_error, true},{use_stdout, false}]),
           Md5Sum   = rebar_utils:sh("md5sum  --version", [{return_on_error, true},{use_stdout, false}]),
           Sort     = rebar_utils:sh("sort    --version", [{return_on_error, true},{use_stdout, false}]),
           FindRes = rebar_utils:sh("find     --version", [{return_on_error, true},{use_stdout, false}]),
           L  = [RsyncRes, FindRes, Md5Sum,Sort,FindRes],
           %?INFO("L: ~p",[L]),
           F = fun(X) -> 
                   case X of 
                       {error,_} -> true;
                       _ -> false
                   end
           end,
           ErrFlag = lists:any(F,L),
           case ErrFlag of 
               true -> 
                   ?ERROR("Check Support Error: ~p",[ErrFlag]),
                    put({is_supported, ?MODULE}, true),
                    put({rsync_ref_function,?MODULE},uuid),
                    ok;
               false -> 
                    put({is_supported, ?MODULE}, true),
                    put({rsync_ref_function,?MODULE},md5sum),
                    ok
            end
    end.

