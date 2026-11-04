# 0012. How the knowledge rules read the predicates

- Status: accepted
- Date: 2026-11-03

## Context

The prompt names eight predicates and the `k_*` and `gap_*` views, but leaves details open: which attributes hold entity names, how a rule says "not this class", how a link names attributes in two signals, how a group of `same_as` signals picks its canonical member, and how gap rows map to work items.

## Decision

- **Entity attributes.** A signal declares the attributes that hold entity names in `source_spec.entity_attributes` (a list). `entity_alias` applies only to those attributes. An attribute value can be one string or a list of strings.
- **Normalization order.** `value_alias` (subject `"<attribute>:<raw value>"`) applies first, then `entity_alias`. Both use the fact that is valid at the observation's `effective_at`. Validity is `[valid_from, valid_to)`.
- **class_rule.** `attributes.equals` is a value or a list. `attributes.signal` optionally limits the rule to one signal. `attributes.negates` is a list of values that explicitly mean "not in this class". An event with such a value is not a gap.
- **link_rule.** The subject is `"<signal A>-><signal B>"` (`→` is also accepted). `attributes.on` is one attribute name, or `[attribute in A, attribute in B]`. `attributes.within` is an ISO 8601 duration. B's event must be at or before A's event and within the duration.
- **entity_attr.** The object is `"key=value"`. `k_event_domain` treats the value as another entity and follows up to four steps to an `entity_domain` fact.
- **same_as.** Subject and object are signal names. Groups are transitive. `attributes.priority` maps signal names to integers, and the lower number wins. Without it, a fact's object ranks 1 and its subject 2. `attributes.tolerance` (absolute) is used by `gap_source_conflict`.
- **min_history.** The object is an integer. History counts series and derived points, and classified events, in the domain.
- **Gap work items.** Every gap view has the columns `subject_id` and `detail`. The gap step opens a work item with `kind = 'gap'`, `subject_type` = the view name, `subject_id` = the row's `subject_id`, and closes open ones whose row has gone.
- **gap_missing_signal.** An events signal can correctly have no events in a window, so "no observations in the window" applies only to series conditions whose window started at least 7 days ago.

## Consequences

A pack author must list entity attributes in each signal's spec. Without the list, `entity_alias`, `k_event_entity`, links and entity domains do nothing for that signal.
