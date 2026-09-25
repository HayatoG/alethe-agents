import Foundation

/// Event types published outside the scheduler (P6-19), with upstream's names.
public extension BusEventType {
    // Merge Center (upstream `merge_analyzer.rs`, `conflict_resolution.rs`).
    static let mergeClean = "MergeClean"
    static let mergeConflict = "MergeConflict"
    static let mergeRequested = "MergeRequested"
    static let mergeValidated = "MergeValidated"
    static let mergeValidationFailed = "MergeValidationFailed"
    static let mergeMerged = "MergeMerged"
    static let mergeAborted = "MergeAborted"
    // Graphify (upstream `graphify.rs`).
    static let graphUpdated = "GraphUpdated"
    // Plugins (upstream `plugins.rs`); `PluginFailed` is native: upstream has no load-failure event.
    static let pluginEnabled = "PluginEnabled"
    static let pluginDisabled = "PluginDisabled"
    static let pluginFailed = "PluginFailed"
    // Resources (upstream `resource_manager.rs`).
    static let resourceMetricsUpdated = "ResourceMetricsUpdated"
}

/// Builders for those events, in upstream's shape: correlation id, task id (the project, where
/// upstream passes one) and snake_case data keys. Payloads carry names, paths and counts only.
public extension BusEvent {
    // MARK: Merge Center

    /// A trial merge finished (upstream `merge_analyze`): `MergeClean` or `MergeConflict`.
    static func mergeAnalyzed(projectID: String?, source: String, target: String, clean: Bool,
                              conflictCount: Int, classes: [String], date: Date = .now) -> BusEvent {
        BusEvent(type: clean ? BusEventType.mergeClean : BusEventType.mergeConflict,
                 correlationID: correlationID(prefix: "merge"), taskID: projectID,
                 data: .object(["source": .string(source), "target": .string(target),
                                "conflict_count": .number(Double(conflictCount)),
                                "classes": .array(classes.map(JSONValue.string))]),
                 date: date)
    }

    /// A merge environment was prepared (upstream `merge_prepare`): `MergeRequested`, then
    /// `MergeConflict` when the merge stopped on conflicts.
    static func mergePrepared(environmentID: String, projectID: String?, source: String, target: String,
                              clean: Bool, conflictCount: Int, environmentPath: String,
                              date: Date = .now) -> [BusEvent] {
        var events = [merge(BusEventType.mergeRequested, environmentID, projectID,
                            ["source": .string(source), "target": .string(target), "clean": .bool(clean)], date)]
        if !clean {
            events.append(merge(BusEventType.mergeConflict, environmentID, projectID,
                                ["conflict_count": .number(Double(conflictCount)),
                                 "env": .string(environmentPath)], date))
        }
        return events
    }

    /// The validation pipeline ran in a merge environment (upstream `validate_stage`): a failure
    /// carries the failing command as `stage`.
    static func mergeValidation(environmentID: String, projectID: String?, failedStage: String?,
                                date: Date = .now) -> BusEvent {
        if let failedStage {
            return merge(BusEventType.mergeValidationFailed, environmentID, projectID,
                         ["stage": .string(failedStage)], date)
        }
        return merge(BusEventType.mergeValidated, environmentID, projectID, [:], date)
    }

    /// The merge was integrated into the target (upstream `merge_finalize`).
    static func mergeMerged(environmentID: String, projectID: String?, source: String, target: String,
                            date: Date = .now) -> BusEvent {
        merge(BusEventType.mergeMerged, environmentID, projectID,
              ["source": .string(source), "target": .string(target)], date)
    }

    /// The merge environment was discarded (upstream `merge_abort`).
    static func mergeAborted(environmentID: String, projectID: String?, date: Date = .now) -> BusEvent {
        merge(BusEventType.mergeAborted, environmentID, projectID, [:], date)
    }

    /// Events of one merge environment share the correlation id `merge-<environment id>`.
    private static func merge(_ type: String, _ environmentID: String, _ projectID: String?,
                              _ data: [String: JSONValue], _ date: Date) -> BusEvent {
        BusEvent(type: type, correlationID: "merge-\(environmentID)", taskID: projectID, data: .object(data), date: date)
    }

    // MARK: Graphify

    /// A repository's graph was generated (upstream bootstrap: `action` "bootstrap"; the native
    /// Regenerate uses "generate").
    static func graphGenerated(repository: String, action: String = "bootstrap", projectID: String? = nil,
                               date: Date = .now) -> BusEvent {
        BusEvent(type: BusEventType.graphUpdated, correlationID: correlationID(prefix: "graphify"), taskID: projectID,
                 data: .object(["action": .string(action), "repo": .string(repository)]), date: date)
    }

    /// A snapshot was put back as the current graph (upstream `graphify_rollback`).
    static func graphRolledBack(snapshotID: String, projectID: String? = nil, date: Date = .now) -> BusEvent {
        BusEvent(type: BusEventType.graphUpdated, correlationID: correlationID(prefix: "graphify"), taskID: projectID,
                 data: .object(["action": .string("rollback"), "snapshot_id": .string(snapshotID)]), date: date)
    }

    // MARK: Plugins

    /// A plugin was enabled or disabled (upstream `plugin_set_enabled`).
    static func pluginEnabledChanged(id: String, enabled: Bool, date: Date = .now) -> BusEvent {
        BusEvent(type: enabled ? BusEventType.pluginEnabled : BusEventType.pluginDisabled,
                 correlationID: "plugin-\(id)",
                 data: .object(["id": .string(id), "enabled": .bool(enabled)]), date: date)
    }

    /// A plugin failed to load or activate.
    static func pluginFailed(id: String, error: String, date: Date = .now) -> BusEvent {
        BusEvent(type: BusEventType.pluginFailed, correlationID: "plugin-\(id)",
                 data: .object(["id": .string(id), "error": .string(error)]), date: date)
    }

    // MARK: Resources

    /// One supervision pass (upstream `publish_metrics`). `memoryPressure` is upstream's level name
    /// (`Ok`, `Low`, `Medium`, `High`, `Critical`); there is no web view, so `webview_mb` is 0.
    static func resourceMetrics(memoryPressure: String, systemAvailableMB: Double, systemTotalMB: Double,
                                appMB: Double, ptysMB: Double, processCount: Int, policyTriggerCount: Int,
                                date: Date = .now) -> BusEvent {
        BusEvent(type: BusEventType.resourceMetricsUpdated, correlationID: "resource-manager",
                 data: .object([
                     "memory_pressure": .string(memoryPressure),
                     "system_available_mb": .number(systemAvailableMB),
                     "system_total_mb": .number(systemTotalMB),
                     "app_mb": .number(appMB),
                     "webview_mb": .number(0),
                     "ptys_mb": .number(ptysMB),
                     "process_count": .number(Double(processCount)),
                     "policy_trigger_count": .number(Double(policyTriggerCount)),
                 ]), date: date)
    }
}
