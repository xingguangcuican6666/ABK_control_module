/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_ABK_CONTROL_H
#define _LINUX_ABK_CONTROL_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define ABK_CONTROL_MAX_COMMAND 160
#define ABK_CONTROL_IOCTL_MAGIC 0xa7
#define ABK_CONTROL_OPS_HAS_RUNTIME_UI 1

struct abk_control_status_cmd {
	__u64 data_len;
	__aligned_u64 data;
};

struct abk_control_command_cmd {
	__u64 command_len;
	__aligned_u64 command;
};

#define ABK_CONTROL_IOCTL_GET_STATUS \
	_IOWR(ABK_CONTROL_IOCTL_MAGIC, 0x41, struct abk_control_status_cmd)
#define ABK_CONTROL_IOCTL_RUN_COMMAND \
	_IOW(ABK_CONTROL_IOCTL_MAGIC, 0x42, struct abk_control_command_cmd)

struct abk_control_manifest_entry {
	const char *id;
	const char *name;
	const char *version;
	const char *description;
	const char *repo_url;
	const char *stage;
	const char *entry_kind;
	const char *extension_id;
	const char *companion_package;
	const char *companion_display_name;
	const char *companion_asset_name;
	const char *companion_download_url;
	const char *service_activity;
	const char *group_id;
	const char *group_name;
	const char *group_role;
	const char *group_description;
	const char *group_repo_url;
	bool requires_companion_app;
	bool settings_supported;
	bool per_app_supported;
	u32 oobe_priority;
};

struct abk_control_build_features {
	bool use_zram;
	bool use_bbg;
	bool use_ddk;
	bool use_ntsync;
	bool use_networking;
	bool use_kpm;
	bool use_rekernel;
	bool enable_susfs;
	bool supp_op;
	bool zram_full_algo;
};

struct abk_control_build_info {
	const char *abk_version;
	const char *abk_commit;
	const char *work_mode;
	const char *android_version;
	const char *kernel_version;
	const char *sub_level;
	const char *os_patch_level;
	const char *revision;
	const char *kernelsu_variant;
	const char *kernelsu_branch;
	const char *version;
	const char *build_time;
	const char *virtualization_support;
	const char *zram_extra_algos;
	struct abk_control_build_features features;
};

struct abk_control_ops {
	const char *id;
	const char *name;
	const char *version;
	const char *description;
	const char *module_dir;
	const char *web_root;
	const char *extension_id;
	const char *companion_package;
	const char *companion_display_name;
	const char *companion_asset_name;
	const char *companion_download_url;
	const char *service_activity;
	bool has_web_ui;
	bool has_action_script;
	bool action_supported;
	bool requires_companion_app;
	bool settings_supported;
	bool per_app_supported;
	u32 oobe_priority;
	bool (*is_enabled)(void *data);
	int (*set_enabled)(bool enabled, void *data);
	int (*run_command)(const char *command, void *data);
	void *data;
};

int abk_control_register(const struct abk_control_ops *ops);
void abk_control_unregister(const struct abk_control_ops *ops);
int abk_control_get_status_json(char **out, size_t *out_len);
int abk_control_run_command(const char *command, size_t command_len);

extern const struct abk_control_manifest_entry abk_control_manifest[];
extern const size_t abk_control_manifest_count;
extern const struct abk_control_build_info abk_control_build;

#endif /* _LINUX_ABK_CONTROL_H */
