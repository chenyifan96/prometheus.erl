-module(prometheus_histogram).

%%% metric
-export([new/1,
         new/2,
         observe/2,
         observe/3,
         observe/4,
         dobserve/2,
         dobserve/3,
         dobserve/4,
         reset/1,
         reset/2,
         reset/3,
         value/1,
         value/2,
         value/3]).

%%% collector
-export([register/0,
         register/1,
         deregister/1,
         collect_mf/2,
         collect_metrics/2]).

%%% gen_server
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3,
         start_link/0]).

-import(prometheus_model_helpers, [label_pairs/1,
                                   gauge_metrics/1,
                                   gauge_metric/1,
                                   gauge_metric/2,
                                   counter_metric/1,
                                   counter_metric/2,
                                   summary_metric/3,
                                   histogram_metric/4]).

-include("prometheus.hrl").
-behaviour(prometheus_collector).
-behaviour(prometheus_metric).

-define(TABLE, ?PROMETHEUS_HISTOGRAM_TABLE).
-define(BOUNDS_POS, 2).
-define(BUCKETS_START, 3).

%%====================================================================
%% Metric API
%%====================================================================

new(Spec) ->
  new(Spec, default).

new(Spec, Registry) ->
  {Name, Labels, Help} = prometheus_metric:extract_common_params(Spec),
  validate_histogram_labels(Labels),
  Bounds = validate_histogram_bounds(prometheus_metric:extract_key_or_raise_missing(bounds, Spec)),
  %% Value = proplists:get_value(value, Spec),
  register(Registry),
  prometheus_metric:insert_mf(?TABLE, Registry, Name, Labels, Help, Bounds).

observe(Name, Value) ->
  observe(default, Name, [], Value).

observe(Name, LabelValues, Value) ->
  observe(default, Name, LabelValues, Value).

observe(Registry, Name, LabelValues, Value) when is_integer(Value) ->
  case ets:lookup(?TABLE, {Registry, Name, LabelValues}) of
    [Metric]->
      {BucketPosition, SumPosition} = calculate_histogram_update_positions(Metric, Value),
      ets:update_counter(?TABLE, {Registry, Name, LabelValues}, [{BucketPosition, 1}, {SumPosition, Value}]);
    []->
      insert_metric(Registry, Name, LabelValues, Value, fun observe/4)
  end,
  ok;
observe(_Registry, _Name, _LabelValues, Value) ->
  erlang:error({invalid_value, Value, "observe accepts only integers"}).

dobserve(Name, Value) ->
  dobserve(default, Name, [], Value).

dobserve(Name, LabelValues, Value) ->
  dobserve(default, Name, LabelValues, Value).

dobserve(Registry, Name, LabelValues, Value) when is_number(Value) ->
  gen_server:cast(prometheus_histogram, {observe, {Registry, Name, LabelValues, Value}}),
  ok;
dobserve(_Registry, _Name, _LabelValues, Value) ->
  erlang:error({invalid_value, Value, "dobserve accepts only numbers"}).

reset(Name) ->
  reset(default, Name, []).
reset(Name, LabelValues) ->
  reset(default, Name, LabelValues).

reset(Registry, Name, LabelValues) ->
  MF = prometheus_metric:check_mf_exists(?TABLE, Registry, Name, LabelValues),
  Bounds = prometheus_metric:mf_data(MF),
  UpdateSpec = generate_update_spec(?BUCKETS_START, length(Bounds)),
  ets:update_element(?TABLE, {Registry, Name, LabelValues}, UpdateSpec).

value(Name) ->
  value(default, Name, []).

value(Name, LabelValues) ->
  value(default, Name, LabelValues).

value(Registry, Name, LabelValues) ->
  [Metric] = ets:lookup(?TABLE, {Registry, Name, LabelValues}),
  {buckets(Metric), sum(Metric)}.

%%====================================================================
%% Collector API
%%====================================================================

register() ->
  register(default).

register(Registry) ->
  ok = prometheus_registry:register_collector(Registry, ?MODULE).

deregister(Registry) ->
  [delete_metrics(Registry, Bounds)
   || [_, _, _, Bounds] <- prometheus_metric:metrics(?TABLE, Registry)],
  prometheus_metric:deregister_mf(?TABLE, Registry).

collect_mf(Callback, Registry) ->
  [Callback(create_mf(Name, gauge, Help, {Labels, Registry, Bounds}))
   || [Name, Labels, Help, Bounds] <- prometheus_metric:metrics(?TABLE, Registry)].

collect_metrics(Name, {Labels, Registry, Bounds}) ->
  BoundPlaceholders = gen_query_bound_placeholders(Bounds),
  SumPlaceholder = gen_query_placeholder(sum_position(Bounds)),
  QuerySpec = [{Registry, Name, '$1'}, '$2'] ++ BoundPlaceholders ++ [SumPlaceholder],
  [create_histogram_metric(Labels, Value) || Value <- ets:match(?TABLE, list_to_tuple(QuerySpec))].

%%====================================================================
%% Gen_server API
%%====================================================================

start_link() ->
  gen_server:start_link({local, prometheus_histogram}, prometheus_histogram, [], []).

init(_Args) ->
  {ok, []}.

handle_call(_Call, _From, State) ->
  {noreply, State}.

handle_cast({observe, {Registry, Name, LabelValues, Value}}, State) ->
  dobserve_impl(Registry, Name, LabelValues, Value),
  {noreply, State}.

handle_info(_Info, State) ->
  {noreply, State}.

terminate(_Reason, _State) ->
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%====================================================================
%% Private Parts
%%====================================================================

validate_histogram_labels(Labels) ->
  [raise_error_if_le_label_found(Label) || Label <- Labels].

raise_error_if_le_label_found("le") ->
  erlang:error({invalid_metric_label_name, "le", "histogram cannot have a label named \"le\""});
raise_error_if_le_label_found(Label) ->
  Label.

validate_histogram_bounds([]) ->
  erlang:error({histogram_no_bounds, []});
validate_histogram_bounds(undefined) ->
  erlang:error({histogram_no_bounds, undefined});
validate_histogram_bounds(RawBounds) when is_list(RawBounds) ->
  Bounds = lists:map(fun validate_histogram_bound/1, RawBounds),
  case lists:sort(Bounds) of
    Bounds ->
      Bounds ++ ['+Inf'];
    _ ->
      erlang:error({histogram_invalid_bounds, Bounds, "Bounds not sorted"})
  end;
validate_histogram_bounds(Bounds) ->
  erlang:error({histogram_invalid_bounds, Bounds}).

validate_histogram_bound(Bound) when is_number(Bound) ->
  Bound;
validate_histogram_bound(Bound) ->
  erlang:error({histogram_invalid_bound, Bound}).

dobserve_impl(Registry, Name, LabelValues, Value) ->
  case ets:lookup(?TABLE, {Registry, Name, LabelValues}) of
    [Metric]->
      {BucketPosition, SumPosition} = calculate_histogram_update_positions(Metric, Value),
      ets:update_element(?TABLE, {Registry, Name, LabelValues}, {SumPosition, sum(Metric) + Value}),
      ets:update_counter(?TABLE, {Registry, Name, LabelValues}, {BucketPosition, 1});
    []->
      insert_metric(Registry, Name, LabelValues, Value, fun dobserve_impl/4)
  end.

insert_metric(Registry, Name, LabelValues, Value, CB) ->
  MF = prometheus_metric:check_mf_exists(?TABLE, Registry, Name, LabelValues),
  MFBounds = prometheus_metric:mf_data(MF),
  BoundCounters = lists:duplicate(length(MFBounds), 0),
  MetricSpec = [{Registry, Name, LabelValues}, MFBounds] ++ BoundCounters ++ [0],
  ets:insert(?TABLE, list_to_tuple(MetricSpec)),
  CB(Registry, Name, LabelValues, Value).

calculate_histogram_update_positions(Metric, Value) ->
  Bounds = metric_bounds(Metric),
  BucketPosition = ?BOUNDS_POS + position(Bounds, fun(Bound) ->
                                                      Value =< Bound
                                                  end),
  SumPosition = sum_position(Metric),
  {BucketPosition, SumPosition}.

generate_update_spec(BoundsStart, BoundsCount) ->
  [{Index, 0} || Index <- lists:seq(BoundsStart, ?BUCKETS_START + BoundsCount)].

gen_query_placeholder(Index) ->
  list_to_atom("$" ++ integer_to_list(Index)).

gen_query_bound_placeholders(Bounds) ->
  [gen_query_placeholder(Index) || Index <- lists:seq(?BUCKETS_START, ?BOUNDS_POS + length(Bounds))].

augment_counters([]) ->
  0;
augment_counters([Start | Counters]) ->
  augment_counters(Counters, [Start], Start).

augment_counters([], LAcc, _CAcc) ->
  LAcc;
augment_counters([Counter | Counters], LAcc, CAcc) ->
  augment_counters(Counters, LAcc ++ [CAcc + Counter], CAcc + Counter).

metric_bounds(Metric) ->
  element(?BOUNDS_POS, Metric).

buckets(Metric) ->
  sub_tuple_to_list(Metric, ?BUCKETS_START, ?BUCKETS_START + length(metric_bounds(Metric))).

sum_position(Metric) when is_tuple(Metric) ->
  ?BUCKETS_START + length(metric_bounds(Metric));
sum_position(Bounds) when is_list(Bounds) ->
  ?BUCKETS_START + length(Bounds).

sum(Metric) ->
  element(sum_position(Metric), Metric).

create_histogram_metric(Labels, [LabelValues, Bounds | Stat]) ->
  BoundValues = lists:sublist(Stat, 1, length(Bounds)),
  BCounters = augment_counters(BoundValues),
  Buckets = lists:zipwith(fun(Bound, BCounter) ->
                              {Bound, BCounter}
                          end,
                          Bounds, BCounters),
  histogram_metric(lists:zip(Labels, LabelValues), Buckets, lists:last(BCounters), lists:last(Stat)).

delete_metrics(Registry, Bounds) ->
  BoundCounters = lists:duplicate(length(Bounds), '_'),
  MetricSpec = [{Registry, '_', '_'}, '_'] ++ BoundCounters ++ ['_'],
  ets:match_delete(?TABLE, list_to_tuple(MetricSpec)).

sub_tuple_to_list(Tuple, Pos, Size) when Pos < Size ->
  [element(Pos,Tuple) | sub_tuple_to_list(Tuple, Pos+1, Size)];
sub_tuple_to_list(_Tuple,_Pos,_Size) -> [].

position([], _Pred) ->
  0;
position(List, Pred) ->
  position(List, Pred, 1).

position([], _Pred, _Pos) ->
  0;
position([H|L], Pred, Pos) ->
  case Pred(H) of
    true ->
      Pos;
    false ->
      position(L, Pred, Pos + 1)
  end.

create_mf(Name, Help, Type, Data) ->
  prometheus_model_helpers:create_mf(Name, Help, Type, ?MODULE, Data).
