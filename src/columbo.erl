-module(columbo).


-export([main/1]).

columbo_dir() ->
    ".columbo".

main(_Args) ->
    ok = ensure_columbo_dir(),
    DepsSpec1 = read_rebar_deps("rebar.config"),
%    DepsSpec2 = [ {{Dep, author_from_url(Url), Treeish}, Url}
%                || {Dep, {Url, Treeish}} <- DepsSpec1],
    DepsSpec2 = lists:map( fun dep_spec_to_node_and_url/1,
                               DepsSpec1 ),
    io:format("DepsSpec2: ~p~n", [DepsSpec2]),
    Authors = [ Author || {_,_,Author,_} <- DepsSpec2],
    ensure_author_dirs(Authors),
    info("Cloning direct dependencies."),
    lists:foreach( fun clone_dep/1, DepsSpec2),
    FirstLevelNodes = [ Node 
                        ||  {Node, _Url} <- DepsSpec2 ],
    info("Checking out dependencies."),
    lists:foreach( fun checkout_dep/1, FirstLevelNodes),
    io:format("~p~n", [FirstLevelNodes]),
    TopLevelNode = determine_top_level_node(),
    io:format("top level: ~p~n", [TopLevelNode]),
    Tree = initialise_tree(TopLevelNode, FirstLevelNodes),
    io:format("nodes: ~p~n", [digraph:vertices(Tree)]),
    io:format("1st level deps: ~p~n", [digraph:out_neighbours(Tree, TopLevelNode)]),
    resolve_tree(Tree, FirstLevelNodes),
    print_tree(Tree),
    write_dot_file(TopLevelNode, Tree).

resolve_tree(_Tree, []) ->
    io:format("Done resolving tree~n");
resolve_tree(Tree, [Node|Nodes]) ->
    ExtraNodes = resolve_node(Tree, Node),
    resolve_tree(Tree, Nodes ++ ExtraNodes).

resolve_node(Tree, Node) ->
    checkout_dep(Node),
    RebarDeps = read_node_deps(Node),
    DepNodesWithUrl = [ dep_spec_to_node_and_url(Spec)
                        || Spec <- RebarDeps ],
    lists:foreach( fun clone_dep/1, DepNodesWithUrl),
    DepNodes = lists:map( fun node_from_node_and_url/1, DepNodesWithUrl ),
    lists:foreach( fun(DepNode) -> 
                           add_dep_to_tree(Tree, Node, DepNode)
                   end,
                   DepNodes ),
    DepNodes.

top_level_author() ->
    Res = execute_cmd("git remote -v"),
    Url = string:tokens(Res, " "),
    author_from_url(Url).

dep_spec_to_node_and_url({Dep, {Url, Treeish}}) ->
    {{Dep, author_from_url(Url), Treeish}, Url}.
    
node_from_node_and_url({Node, _Url}) -> Node.

print_tree(Tree) ->
    Vertices = digraph_utils:preorder(Tree),
    lists:foreach(fun (Node) -> 
                          print_node(Node, digraph:out_neighbours(Tree, Node))
                  end,
                  Vertices).

print_node(Node, Neighbours) ->
    io:format("~p -> ~p~n", [Node, Neighbours]).

clone_dep({{Dep, Author, _Treeish}, Url}) ->
    Cmd = io_lib:format("git clone ~p ~p/~p/~p",
                        [Url, columbo_dir(), Author, Dep]),
    execute_cmd(Cmd).

checkout_dep({Dep, Author, Treeish}) ->
    CurrentDir = current_dir(),
    cd_columbo_deps_dir(Author, Dep),
    checkout_treeish(Treeish),
    cd_dir(CurrentDir),
    ok.

checkout_treeish(undefined) ->
    checkout_treeish("HEAD");
checkout_treeish("HEAD") ->
    Cmd = "git checkout master",
    info(Cmd),
    execute_cmd(Cmd);
checkout_treeish({tag, Tag}) ->
    Cmd = io_lib:format("git checkout ~s", [Tag]),
    info(Cmd),
    execute_cmd(Cmd);
checkout_treeish({branch, Branch}) ->
    Cmd = io_lib:format("git checkout ~s", [Branch]),
    execute_cmd(Cmd);
checkout_treeish(CommitHash) ->
    Cmd = io_lib:format("git checkout ~s", [CommitHash]),
    execute_cmd(Cmd).

info(Str) ->
    io:format("~s~n", [Str]).


ensure_columbo_dir() ->
    ensure_dir(columbo_dir()).

ensure_author_dirs(Authors) ->
    lists:foreach(fun(Author) -> io_lib:format("~s/~p", [columbo_dir(), Author]) end,
                  Authors).

ensure_dir(Dir) ->
    case file:make_dir(Dir) of
        ok ->
            ok;
        {error, eexist} ->
            ok;
        Error ->
            Error
    end.

current_version(Dep) ->
%%    Cmd = "git describe --always --tags",
    CurrentDir = current_dir(),
    cd_deps_dir(CurrentDir, Dep),
    {Tag,_Description} = current_tag_and_branch(),
%%    Res = trim_version_string(execute_cmd(Cmd)),
    cd_dir(CurrentDir),
    Tag.

current_tag_and_branch() ->
    Cmd1 = "git describe --always --tags",
    Tag  = trim_version_string(execute_cmd(Cmd1)),
    Cmd2 = "git branch",
    Branch = trim_version_string(execute_cmd(Cmd2)),
    {Tag, Branch}.


determine_top_level_node() ->
    case find_app_src(".") of
        error ->
            % application with only deps, ie riak
            {Tag, _Branch} = current_tag_and_branch(),
            {current_dir_as_app_name(), Tag};
        AppSrc ->
            case file:consult("src/" ++ AppSrc) of
                {ok, [{application, App, _}]} ->
                    {Tag, _Branch} = current_tag_and_branch(),
                    {App, Tag};
                _ ->
                    bogus_app_src
            end
    end.
        

initialise_tree({Dep, Tag}, FirstLevelNodes) ->
    Tree = digraph:new(),
    Author = top_level_author(),
    Root = {Dep, Author, Tag}, 
    digraph:add_vertex(Tree, Root),
    lists:foreach(fun(Node) -> add_dep_to_tree(Tree, Root, Node) end,
                  FirstLevelNodes),
    Tree.

add_dep_to_tree(Tree, Parent, Node) ->
    digraph:add_vertex(Tree, Node),
    case does_edge_exist(Tree, Parent, Node) of
        true ->
            ok;
        false ->
            digraph:add_edge(Tree, Parent, Node)
    end.

does_edge_exist(Tree, From, To) ->
    lists:member(To, digraph:out_neighbours(Tree, From)).
   
tail_tags(Dep) ->
    Cmd = "git tag -l \"[0-9]*\" -l \"v[0-9]*\"",
    CurrentDir = current_dir(),
    cd_deps_dir(CurrentDir, Dep),
    Res = string:tokens(execute_cmd(Cmd), "\n"),
    Relevant = tail(lists:sort([strip_v(R) || R <- Res]), 5),
    Cmd2 = "git tag -l \"[0-9]*.*p[0-9]*\" -l \"v[0-9]*.*p[0-9]*\" \"[0-9]*.*basho[0-9]*\" -l \"v[0-9]*.*basho[0-9]*\"",
    Res2 = string:tokens(execute_cmd(Cmd2), "\n"),
    Relevant2 = tail(lists:sort([strip_v(R) || R <- Res2]), 5),
    cd_dir(CurrentDir),
    io:format("~p tags: ~p~n", [Dep, Relevant]),
    io:format("~p Basho tags: ~p~n", [Dep, Relevant2]).

tail(Ls, N) when length(Ls) < N ->
    Ls;
tail(Ls, N) ->
    lists:nthtail(length(Ls) - N, Ls).

strip_v([$v|Vsn]) -> Vsn;
strip_v(Vsn) -> Vsn.


print_deps(Dep, Deps) ->
    io:format("~p deps:~n", [Dep]),
    [ io:format("    ~p~n", [D]) || D <-Deps].

cd_dir(Dir) ->
    info("cd " ++ Dir),
    ok = file:set_cwd(Dir).

cd_deps_dir(CurrentDir, Dep) ->
    Dir = lists:flatten(io_lib:format("~s/deps/~p", [CurrentDir, Dep])),
    cd_dir(Dir).

cd_columbo_deps_dir(Author, Dep) ->
    Dir = lists:flatten(io_lib:format("~s/~s/~p",
                                      [columbo_dir(), erlang:atom_to_list(Author), Dep])),
    cd_dir(Dir).

execute_cmd(Cmd) ->
    os:cmd(Cmd).

current_dir() ->
    {ok, Dir} = file:get_cwd(),
    Dir.

current_dir_as_app_name() ->
    list_to_atom(hd(lists:reverse(string:tokens(current_dir(), "/")))).

trim_version_string(S) ->
    string:strip(S, both, hd("\n")).

dep_deps(Dep) ->
    FileName = lists:flatten(io_lib:format("./deps/~p/rebar.config", [Dep])),
    case file:consult(FileName) of
         {ok, Terms} ->
            RawDeps = proplists:get_value(deps, Terms, []),
            pretty_deps(RawDeps);
        {error, enoent} ->
            []
    end.

read_rebar_deps(Filename) ->
    case file:consult(Filename) of
         {ok, Terms} ->
            RawDeps = proplists:get_value(deps, Terms, []),
            pretty_deps(RawDeps);
        {error, enoent} ->
            []
    end.

read_node_deps({Node, Author, _Treeish}) ->
    Filename = io_lib:format(columbo_dir() ++ "/~p/~p/rebar.config", 
                             [Author, Node]),
    read_rebar_deps(Filename).

pretty_deps(Deps) ->
    [ pretty_dep(Dep)
      || Dep <- Deps ].

pretty_dep({Dep, _Req, Git}) ->
    {Dep, extract_git_info(Git)}.

extract_git_info({git, Url}) ->
    extract_git_info({git, Url, undefined});
extract_git_info({git, Url, Info}) ->
    {Url, Info}.

author_from_url(Url) ->
    % NOTE: support for the following Url formats:
    % * http[s]://github.com/author/repo
    % * git@github.com:author/repo
    %
    % As well as some uninformed, but acceptible formats:
    % * git@github.com:/author/repo
    case re:run(Url,
            "(git@|git://|http[s]?://)([^:/]+\.[^:/]+)[:/]+(.*)[/]",
            [{capture, all, list}]) of
        {match, [_All, _Proto, _Host, Author]} -> 
            erlang:list_to_atom(Author);
        _ ->
            error({invalid_git_url, Url})
    end.

write_dot_file({App, Tag}=_Root, Tree) ->
    Filename = lists:flatten(io_lib:format("~p-~s.dot", [App, Tag])),
    Header = header(Filename),
    End    = "}",
    NodeStrings = node_strings(Tree),
    EdgeStrings = edge_strings(Tree),
    file:write_file(Filename,
                    lists:flatten([Header,
                                   NodeStrings,
                                   EdgeStrings,
                                   End])).

header(Str) ->
    io_lib:format("digraph ~p {~n", [Str]).

node_strings(Tree) ->
    Nodes = digraph:vertices(Tree),
    Clusters = split_clusters(Nodes),
    [ cluster_string(Cluster) 
      || Cluster <- maps:to_list(Clusters) ].

edge_strings(Tree) ->
    Nodes = digraph:vertices(Tree),
    lists:flatten([ out_edges_strings(Node, Tree) 
                    || Node <- Nodes ]).

out_edges_strings(Node, Tree) ->
    Neighbours = digraph:out_neighbours(Tree, Node),
    [ edge_string(Node, To)
      || To <- Neighbours ].

edge_string({FromDep, FromAuthor, FromVsn}, 
            {ToDep, ToAuthor, ToVsn}) ->
    io_lib:format("~s -> ~s;~n", [version_node_name(FromDep, {FromAuthor, FromVsn}),
                                  version_node_name(ToDep, {ToAuthor, ToVsn})]).

split_clusters(Nodes) ->
    split_clusters(Nodes, #{}).

split_clusters([], Clusters) ->
    Clusters;
split_clusters([Node|Nodes], Clusters) ->
    split_clusters(Nodes, add_node_to_clusters(Node, Clusters)).

add_node_to_clusters({Dep, Tag}, Clusters) ->
    maps:put(Dep, [Tag], Clusters);
add_node_to_clusters({Dep, Author, Treeish}=Node, Clusters) ->
    case maps:find(Dep, Clusters) of
        error ->
            maps:put(Dep, [{Author, Treeish}], Clusters);
        {ok, Nodes} ->
            maps:put(Dep, [{Author, Treeish}|Nodes], Clusters)
    end.

cluster_string({Dep, Versions}) ->
    Header = io_lib:format("subgraph cluster~p {~n", [Dep]),
    Label  = lists:flatten(io_lib:format("label = \"~p\";~n ", [Dep])),
    Nodes  = [ version_node_string(Dep, Version)
               || Version <- Versions ],
    End    = io_lib:format("}~n ", []),
    lists:flatten([Header,
                   Label,
                   Nodes,
                   End]).

version_node_string(Dep, AuthorVsn) ->
    Label = version_label(Dep, AuthorVsn),
    NodeName = version_node_name(Dep, AuthorVsn),
    io_lib:format("~s [label=\"~s\"];~n", [NodeName, Label]).  



version_label(Dep, {Author, {tag, Tag}}) ->
    io_lib:format("{~p, {tag, ~s}}", [Author, Tag]);
version_label(Dep, {Author, {branch, Branch}}) ->
    io_lib:format("{~p, {branch, ~s}}", [Author, Branch]);
version_label(Dep, {Author, "HEAD"}) ->
    io_lib:format("{~p, {branch, ~s}}", [Author, "master"]);
version_label(Dep, {TopLevelAuthor, TopLevelTag}) ->
    io_lib:format("{~p, ~s}", [TopLevelAuthor, TopLevelTag]).

version_node_name(Dep, AuthorVsn) ->
    Label = version_label(Dep, AuthorVsn),
    io_lib:format("\"~p-~s\"", [Dep, Label]).  
    

%% utility functions

%% @doc postfix(Pattern, String) returns true if String ends in Pattern.
postfix(Pattern, String) ->
    lists:prefix(lists:reverse(Pattern), lists:reverse(String)).

find_app_src(Dir) ->
    Filenames = case file:list_dir(Dir ++ "/src") of
        {ok, Filenames0} -> Filenames0;
        _ -> []
    end,
    case [ File || File <- Filenames, postfix(".app.src", File) ] of
        [AppSrc] -> AppSrc;
        _ -> error
    end.

