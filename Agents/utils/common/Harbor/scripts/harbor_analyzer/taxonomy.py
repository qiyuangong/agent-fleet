"""Closed canonical Analyzer taxonomy with class-specific unmapped escape hatches."""

FINAL_CLASSES = ("success", "env_fail", "infra_fail", "model_fail", "unknown")
ENV_INFRA_CLASSES = ("env_fail", "infra_fail")
ANALYSIS_STATUSES = ("analysis_complete", "analysis_failed")

FAILURE_STAGES = (
    "none",
    "task_config",
    "environment_setup",
    "agent_setup",
    "agent_execution",
    "verifier",
    "result_persistence",
    "harbor_runner",
    "external_service",
    "unknown",
)

SCOPES = ("task", "benchmark", "host")
RECOMMENDED_EVENTS = ("notify_user",)
UNKNOWN_ROOT_CAUSE = "insufficient_or_conflicting_evidence"
UNMAPPED_ROOT_CAUSE_BY_CLASS = {
    "env_fail": "unmapped_env_fail",
    "infra_fail": "unmapped_infra_fail",
    "model_fail": "unmapped_model_fail",
}
ALLOWED_FAILURE_STAGES_BY_CLASS = {
    "success": ("none",),
    "env_fail": ("task_config", "environment_setup", "verifier", "result_persistence"),
    "infra_fail": (
        "environment_setup",
        "agent_setup",
        "agent_execution",
        "verifier",
        "result_persistence",
        "harbor_runner",
        "external_service",
    ),
    "model_fail": ("agent_execution", "verifier"),
    "unknown": ("unknown",),
}
ALLOWED_SCOPES_BY_CLASS = {
    "success": ("task",),
    "env_fail": SCOPES,
    "infra_fail": SCOPES,
    "model_fail": SCOPES,
    "unknown": SCOPES,
}

CANONICAL_CLASS_CODES = {
    "infra_fail": {
        "docker_registry_mirror_forbidden",
        "docker_image_mirror_403",
        "registry_mirror_403",
        "docker_buildkit_failure",
        "docker_daemon_unreachable",
        "llm_api_no_response_timeout",
        "provider_responses_api_unsupported",
        "verifier_api_responses_endpoint_unsupported",
        "gpu_environment_unavailable",
        "docker_environment_no_gpu",
        "docker_image_platform_unavailable",
        "platform_manifest_unavailable",
        "platform_not_in_manifest",
        "agent_runtime_node_incompatible",
        "nodejs_runtime_unavailable",
        "nodesource_setup_failed",
        "claude_tgz_missing",
        "claude_code_tgz_missing",
        "prepackaged_tgz_missing",
        "prebuilt_claude_code_tgz_missing",
        "npm_apt_package_conflicts",
        "npm_pkg_dep_conflict",
        "apt_npm_conflicts",
        "incompatible_node_version",
        "missing_claude_tgz",
        "agent_runtime_unquoted_append_system_prompt",
        "unquoted_append_system_prompt",
        "unquoted_system_prompt",
        "append_system_prompt_unquoted",
        "agent_adapter_shell_quoting_bug",
        "agent_adapter_shell_quoting_error",
        "agent_adapter_arg_quoting_bug",
        "agent_adapter_cli_arg_quoting_error",
        "agent_adapter_command_quoting_bug",
        "agent_adapter_command_quoting_error",
        "agent_runtime_command_quoting_error",
        "agent_runtime_shell_quoting_error",
        "command_quoting_error",
        "shell_quoting_error",
        "agent_runtime_prompt_delivery_failure",
        "agent_runtime_prompt_not_delivered",
        "agent_prompt_not_delivered",
        "agent_prompt_not_passed_to_model",
        "external_huggingface_rate_limit",
        "huggingface_api_rate_limited",
        "hf_hub_rate_limit",
        "external_service_rate_limited",
        "task_data_fetch_rate_limited",
    },
    "env_fail": {
        "task_config_missing_required_field",
        "task_data_lfs_pointer_unresolved",
        "git_lfs_pointer_unresolved",
        "lfs_pointer_not_resolved",
        "lfs_pointer_not_materialized",
        "database_file_is_unresolved_git_lfs",
        "gold_duckdb_git_lfs",
        "verifier_code_injection_missing_file",
        "missing_answer_file_instruction",
        "financeagent_prompt_missing_answer_file_instruction",
        "verifier_reward_json_contains_non_numeric",
        "verifier_reward_non_numeric",
        "verifier_reward_schema_mismatch",
        "verifier_result_schema_mismatch",
        "verifier_result_rejects_nonnumeric",
        "kumo_verifier_reward_json",
        "gold_database_not_valid",
        "verifier_db_file_not_valid_sqlite",
        "verifier_database_file_not_valid_sqlite",
        "verifier_data_download_invalid_hdf5",
    },
    "success": {
        "scored_complete_no_failure",
    },
    "model_fail": {
        "model_output_incorrect",
    },
}


def expected_final_class_for_root_cause(root_cause_code: str | None) -> str | None:
    if not isinstance(root_cause_code, str):
        return None
    code = root_cause_code.lower()
    for expected_class, unmapped_code in UNMAPPED_ROOT_CAUSE_BY_CLASS.items():
        if code == unmapped_code:
            return expected_class
    if code == UNKNOWN_ROOT_CAUSE:
        return "unknown"
    for expected_class, codes in CANONICAL_CLASS_CODES.items():
        if code in codes:
            return expected_class
    return None


def allowed_failure_stages_for_root_cause(root_cause_code: str | None) -> tuple[str, ...]:
    expected_class = expected_final_class_for_root_cause(root_cause_code)
    if expected_class is None:
        return ()
    return ALLOWED_FAILURE_STAGES_BY_CLASS[expected_class]


def allowed_scopes_for_root_cause(root_cause_code: str | None) -> tuple[str, ...]:
    expected_class = expected_final_class_for_root_cause(root_cause_code)
    if expected_class is None:
        return ()
    return ALLOWED_SCOPES_BY_CLASS[expected_class]
