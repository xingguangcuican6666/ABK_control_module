// SPDX-License-Identifier: GPL-2.0
#include <linux/abk_control.h>
#include <linux/errno.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/string.h>

#define ABK_CONTROL_INITIAL_BUFFER 1024

struct abk_control_registration {
	const struct abk_control_ops *ops;
	struct list_head node;
};

struct abk_control_buffer {
	char *data;
	size_t len;
	size_t cap;
};

static LIST_HEAD(abk_control_registry);
static DEFINE_MUTEX(abk_control_lock);

static int abk_control_buf_reserve(struct abk_control_buffer *buf, size_t need)
{
	char *next;
	size_t cap = buf->cap;

	if (need <= buf->cap)
		return 0;

	if (!cap)
		cap = ABK_CONTROL_INITIAL_BUFFER;

	while (cap < need) {
		size_t doubled = cap * 2;

		if (doubled <= cap)
			return -EOVERFLOW;
		cap = doubled;
	}

	next = krealloc(buf->data, cap, GFP_KERNEL);
	if (!next)
		return -ENOMEM;

	buf->data = next;
	buf->cap = cap;
	return 0;
}

static int abk_control_buf_append_mem(struct abk_control_buffer *buf,
				      const char *data, size_t len)
{
	int ret;

	ret = abk_control_buf_reserve(buf, buf->len + len + 1);
	if (ret)
		return ret;

	memcpy(buf->data + buf->len, data, len);
	buf->len += len;
	buf->data[buf->len] = '\0';
	return 0;
}

static int abk_control_buf_append(struct abk_control_buffer *buf,
				  const char *text)
{
	return abk_control_buf_append_mem(buf, text, strlen(text));
}

static int abk_control_buf_appendf(struct abk_control_buffer *buf,
				   const char *fmt, ...)
{
	va_list args;
	int ret;

	while (true) {
		size_t avail;
		int needed;

		ret = abk_control_buf_reserve(buf, buf->len + 1);
		if (ret)
			return ret;

		avail = buf->cap - buf->len;
		va_start(args, fmt);
		needed = vsnprintf(buf->data + buf->len, avail, fmt, args);
		va_end(args);

		if (needed < 0)
			return needed;

		if ((size_t)needed < avail) {
			buf->len += needed;
			return 0;
		}

		ret = abk_control_buf_reserve(buf, buf->len + needed + 1);
		if (ret)
			return ret;
	}
}

static int abk_control_buf_append_json_string(struct abk_control_buffer *buf,
					      const char *value)
{
	const unsigned char *cursor = (const unsigned char *)(value ? value : "");
	int ret;

	ret = abk_control_buf_append(buf, "\"");
	if (ret)
		return ret;

	for (; *cursor; cursor++) {
		switch (*cursor) {
		case '\\':
			ret = abk_control_buf_append(buf, "\\\\");
			break;
		case '"':
			ret = abk_control_buf_append(buf, "\\\"");
			break;
		case '\b':
			ret = abk_control_buf_append(buf, "\\b");
			break;
		case '\f':
			ret = abk_control_buf_append(buf, "\\f");
			break;
		case '\n':
			ret = abk_control_buf_append(buf, "\\n");
			break;
		case '\r':
			ret = abk_control_buf_append(buf, "\\r");
			break;
		case '\t':
			ret = abk_control_buf_append(buf, "\\t");
			break;
		default:
			if (*cursor < 0x20)
				ret = abk_control_buf_appendf(buf, "\\u%04x",
							     *cursor);
			else
				ret = abk_control_buf_append_mem(buf,
								(const char *)cursor,
								1);
			break;
		}
		if (ret)
			return ret;
	}

	return abk_control_buf_append(buf, "\"");
}

static int abk_control_buf_append_json_field(struct abk_control_buffer *buf,
					     const char *name,
					     const char *value,
					     bool trailing_comma)
{
	int ret;

	ret = abk_control_buf_appendf(buf, "    \"%s\": ", name);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_string(buf, value);
	if (ret)
		return ret;
	return abk_control_buf_append(buf, trailing_comma ? ",\n" : "\n");
}

static int abk_control_buf_append_json_bool_field(struct abk_control_buffer *buf,
						  const char *name,
						  bool value,
						  bool trailing_comma)
{
	int ret;

	ret = abk_control_buf_appendf(buf, "      \"%s\": %s", name,
				     value ? "true" : "false");
	if (ret)
		return ret;
	return abk_control_buf_append(buf, trailing_comma ? ",\n" : "\n");
}

static int abk_control_buf_append_json_inline_bool(struct abk_control_buffer *buf,
						   const char *name,
						   bool value,
						   bool trailing_comma)
{
	int ret;

	ret = abk_control_buf_appendf(buf, "\"%s\": %s", name,
				     value ? "true" : "false");
	if (ret)
		return ret;
	return abk_control_buf_append(buf, trailing_comma ? ", " : "");
}

static const char *abk_control_effective_work_mode(void)
{
	const char *work_mode = abk_control_build.work_mode;

	if (work_mode && !strcmp(work_mode, "lkm"))
		return "lkm";
	return "built-in";
}

static int abk_control_append_manager_info(struct abk_control_buffer *buf)
{
	const char *work_mode = abk_control_effective_work_mode();
	int ret;

	ret = abk_control_buf_append(buf, "  \"manager\": {\n");
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "display_name",
					       "ABK Control", true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "variant",
					       abk_control_build.kernelsu_variant,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "backend", "kernel", true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "version",
					       abk_control_build.version,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append(buf, "    \"active\": true,\n");
	if (ret)
		return ret;
	return abk_control_buf_appendf(buf,
				       "    \"capabilities\": [\"build\", \"modules\", \"abk_control\"%s]\n"
				       "  },\n",
				       !strcmp(work_mode, "lkm") ? ", \"lkm\"" : "");
}

static int abk_control_append_build_info(struct abk_control_buffer *buf)
{
	int ret;

	ret = abk_control_buf_append_json_field(buf, "abk_version",
					       abk_control_build.abk_version,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "abk_commit",
					       abk_control_build.abk_commit,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "work_mode",
					       abk_control_effective_work_mode(),
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append(buf, "  \"build\": {\n");
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "android_version",
					       abk_control_build.android_version,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "kernel_version",
					       abk_control_build.kernel_version,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "sub_level",
					       abk_control_build.sub_level,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "os_patch_level",
					       abk_control_build.os_patch_level,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "revision",
					       abk_control_build.revision,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "kernelsu_variant",
					       abk_control_build.kernelsu_variant,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "kernelsu_branch",
					       abk_control_build.kernelsu_branch,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "version",
					       abk_control_build.version,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "build_time",
					       abk_control_build.build_time,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "virtualization_support",
					       abk_control_build.virtualization_support,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_field(buf, "zram_extra_algos",
					       abk_control_build.zram_extra_algos,
					       true);
	if (ret)
		return ret;
	ret = abk_control_buf_append(buf, "    \"features\": {\n");
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "use_zram",
						    abk_control_build.features.use_zram,
						    true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "use_bbg",
						    abk_control_build.features.use_bbg,
						    true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "use_ddk",
						    abk_control_build.features.use_ddk,
						    true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "use_ntsync",
						    abk_control_build.features.use_ntsync,
						    true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "use_networking",
						    abk_control_build.features.use_networking,
						    true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "use_kpm",
						    abk_control_build.features.use_kpm,
						    true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "use_rekernel",
						    abk_control_build.features.use_rekernel,
						    true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "enable_susfs",
						    abk_control_build.features.enable_susfs,
						    true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "supp_op",
						    abk_control_build.features.supp_op,
						    true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_bool_field(buf, "zram_full_algo",
						    abk_control_build.features.zram_full_algo,
						    false);
	if (ret)
		return ret;
	return abk_control_buf_append(buf, "    }\n  },\n");
}

static const struct abk_control_ops *abk_control_find_locked(const char *id)
{
	struct abk_control_registration *registration;

	list_for_each_entry(registration, &abk_control_registry, node) {
		if (registration->ops && registration->ops->id &&
		    !strcmp(registration->ops->id, id))
			return registration->ops;
	}

	return NULL;
}

static bool abk_control_manifest_has_id(const char *id)
{
	size_t i;

	for (i = 0; i < abk_control_manifest_count; i++) {
		if (abk_control_manifest[i].id &&
		    !strcmp(abk_control_manifest[i].id, id))
			return true;
	}

	return false;
}

static bool abk_control_ops_enabled(const struct abk_control_ops *ops)
{
	if (ops && ops->is_enabled)
		return ops->is_enabled(ops->data);
	return true;
}

static bool abk_control_is_module_set_child(const char *entry_kind)
{
	return entry_kind && !strcmp(entry_kind, "module_set_child");
}

static bool abk_control_should_expose_extension_module(const char *entry_kind,
						       const char *extension_id)
{
	return extension_id && extension_id[0] &&
	       !abk_control_is_module_set_child(entry_kind);
}

static int abk_control_append_module(struct abk_control_buffer *buf,
				     bool *first,
				     const char *id,
				     const char *name,
				     const char *version,
				     const char *description,
				     const char *repo_url,
				     const char *stage,
				     const char *entry_kind,
				     const char *extension_id,
				     const char *companion_package,
				     const char *companion_display_name,
				     const char *companion_asset_name,
				     const char *companion_download_url,
				     const char *service_activity,
				     const char *group_id,
				     const char *group_name,
				     const char *group_role,
				     const char *group_description,
				     const char *group_repo_url,
				     const char *source,
				     const char *module_dir,
				     const char *web_root,
				     bool requires_companion_app,
				     bool settings_supported,
				     bool per_app_supported,
				     u32 oobe_priority,
				     bool has_web_ui,
				     bool has_action_script,
				     bool action_supported,
				     bool controllable,
				     bool enabled)
{
	int ret;

	ret = abk_control_buf_append(buf, *first ? "\n    {" : ",\n    {");
	if (ret)
		return ret;
	*first = false;

#define ABK_JSON_FIELD(name, value)					\
	do {								\
		ret = abk_control_buf_append(buf, "\"" name "\": ");	\
		if (ret)						\
			return ret;					\
		ret = abk_control_buf_append_json_string(buf, value);	\
		if (ret)						\
			return ret;					\
		ret = abk_control_buf_append(buf, ", ");		\
		if (ret)						\
			return ret;					\
	} while (0)

	ABK_JSON_FIELD("id", id);
	ABK_JSON_FIELD("name", name);
	ABK_JSON_FIELD("version", version);
	ABK_JSON_FIELD("description", description);
	ABK_JSON_FIELD("repo_url", repo_url);
	ABK_JSON_FIELD("stage", stage);
	ABK_JSON_FIELD("entry_kind", entry_kind);
	ABK_JSON_FIELD("extension_id", extension_id);
	ABK_JSON_FIELD("companion_package", companion_package);
	ABK_JSON_FIELD("companion_display_name", companion_display_name);
	ABK_JSON_FIELD("companion_asset_name", companion_asset_name);
	ABK_JSON_FIELD("companion_download_url", companion_download_url);
	ABK_JSON_FIELD("service_activity", service_activity);
	ABK_JSON_FIELD("group_id", group_id);
	ABK_JSON_FIELD("group_name", group_name);
	ABK_JSON_FIELD("group_role", group_role);
	ABK_JSON_FIELD("group_description", group_description);
	ABK_JSON_FIELD("group_repo_url", group_repo_url);
	ABK_JSON_FIELD("type", "builtin");
	ABK_JSON_FIELD("source", source);
	ABK_JSON_FIELD("module_dir", module_dir);
	ABK_JSON_FIELD("web_root", web_root);

#undef ABK_JSON_FIELD

	ret = abk_control_buf_append_json_inline_bool(buf, "readonly",
						     !controllable, true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_inline_bool(buf, "controllable",
						     controllable, true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_inline_bool(buf, "enabled",
						     enabled, true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_inline_bool(buf, "requires_companion_app",
						     requires_companion_app,
						     true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_inline_bool(buf, "settings_supported",
						     settings_supported,
						     true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_inline_bool(buf, "per_app_supported",
						     per_app_supported,
						     true);
	if (ret)
		return ret;
	ret = abk_control_buf_appendf(buf, "\"oobe_priority\": %u, ",
				     oobe_priority);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_inline_bool(buf, "has_web_ui",
						     has_web_ui, true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_inline_bool(buf, "has_action_script",
						     has_action_script, true);
	if (ret)
		return ret;
	ret = abk_control_buf_append_json_inline_bool(buf, "action_supported",
						     action_supported, false);
	if (ret)
		return ret;
	ret = abk_control_buf_append(buf, "}");
	return ret;
}

static int abk_control_build_status(char **out, size_t *out_len)
{
	struct abk_control_registration *registration;
	struct abk_control_buffer buf = {};
	bool first = true;
	bool extension_first = true;
	size_t i;
	int ret;

	ret = abk_control_buf_append(&buf, "{\n  \"schema\": 6,\n");
	if (ret)
		goto err;
	ret = abk_control_append_manager_info(&buf);
	if (ret)
		goto err;
	ret = abk_control_append_build_info(&buf);
	if (ret)
		goto err;
	ret = abk_control_buf_append(&buf, "  \"modules\": [");
	if (ret)
		goto err;

	mutex_lock(&abk_control_lock);

	for (i = 0; i < abk_control_manifest_count; i++) {
		const struct abk_control_manifest_entry *entry;
		const struct abk_control_ops *ops;

		entry = &abk_control_manifest[i];
		ops = entry->id ? abk_control_find_locked(entry->id) : NULL;

		ret = abk_control_append_module(&buf, &first,
						entry->id,
						entry->name,
						entry->version,
						entry->description,
						entry->repo_url,
						entry->stage,
						entry->entry_kind,
						entry->extension_id,
						entry->companion_package,
						entry->companion_display_name,
						entry->companion_asset_name,
						entry->companion_download_url,
						ops ? ops->service_activity : entry->service_activity,
						entry->group_id,
						entry->group_name,
						entry->group_role,
						entry->group_description,
						entry->group_repo_url,
						"abk",
						ops ? ops->module_dir : "",
						ops ? ops->web_root : "",
						ops ? ops->requires_companion_app : entry->requires_companion_app,
						ops ? ops->settings_supported : entry->settings_supported,
						ops ? ops->per_app_supported : entry->per_app_supported,
						ops ? ops->oobe_priority : entry->oobe_priority,
						ops ? ops->has_web_ui : false,
						ops ? ops->has_action_script : false,
						ops ? ops->action_supported : false,
						ops && ops->set_enabled,
						abk_control_ops_enabled(ops));
		if (ret)
			goto unlock_err;
	}

	list_for_each_entry(registration, &abk_control_registry, node) {
		const struct abk_control_ops *ops = registration->ops;

		if (!ops || !ops->id || abk_control_manifest_has_id(ops->id))
			continue;

		ret = abk_control_append_module(&buf, &first,
						ops->id,
						ops->name,
						ops->version,
						ops->description,
						"",
						"runtime",
						"module",
						ops->extension_id,
						ops->companion_package,
						ops->companion_display_name,
						ops->companion_asset_name,
						ops->companion_download_url,
						ops->service_activity,
						"",
						"",
						"",
						"",
						"",
						"abk",
						ops->module_dir,
						ops->web_root,
						ops->requires_companion_app,
						ops->settings_supported,
						ops->per_app_supported,
						ops->oobe_priority,
						ops->has_web_ui,
						ops->has_action_script,
						ops->action_supported,
						ops->set_enabled != NULL,
						abk_control_ops_enabled(ops));
		if (ret)
			goto unlock_err;
	}

	mutex_unlock(&abk_control_lock);

	ret = abk_control_buf_append(&buf, "\n  ],\n  \"extension_modules\": [");
	if (ret)
		goto err;

	mutex_lock(&abk_control_lock);

	for (i = 0; i < abk_control_manifest_count; i++) {
		const struct abk_control_manifest_entry *entry;
		const struct abk_control_ops *ops;
		const char *effective_entry_kind;
		const char *effective_extension_id;
		const char *effective_companion_package;
		const char *effective_companion_display_name;
		const char *effective_companion_asset_name;
		const char *effective_companion_download_url;
		const char *effective_service_activity;
		bool effective_requires_companion_app;
		bool effective_settings_supported;
		bool effective_per_app_supported;
		u32 effective_oobe_priority;

		entry = &abk_control_manifest[i];
		ops = entry->id ? abk_control_find_locked(entry->id) : NULL;
		effective_entry_kind = entry->entry_kind;
		effective_extension_id = entry->extension_id;
		effective_companion_package = entry->companion_package;
		effective_companion_display_name = entry->companion_display_name;
		effective_companion_asset_name = entry->companion_asset_name;
		effective_companion_download_url = entry->companion_download_url;
		effective_service_activity =
			ops ? ops->service_activity : entry->service_activity;
		effective_requires_companion_app =
			ops ? ops->requires_companion_app : entry->requires_companion_app;
		effective_settings_supported =
			ops ? ops->settings_supported : entry->settings_supported;
		effective_per_app_supported =
			ops ? ops->per_app_supported : entry->per_app_supported;
		effective_oobe_priority =
			ops ? ops->oobe_priority : entry->oobe_priority;

		if (!abk_control_should_expose_extension_module(effective_entry_kind,
								effective_extension_id))
			continue;

		ret = abk_control_append_module(&buf, &extension_first,
						entry->id,
						entry->name,
						entry->version,
						entry->description,
						entry->repo_url,
						entry->stage,
						effective_entry_kind,
						effective_extension_id,
						effective_companion_package,
						effective_companion_display_name,
						effective_companion_asset_name,
						effective_companion_download_url,
						effective_service_activity,
						entry->group_id,
						entry->group_name,
						entry->group_role,
						entry->group_description,
						entry->group_repo_url,
						"abk",
						ops ? ops->module_dir : "",
						ops ? ops->web_root : "",
						effective_requires_companion_app,
						effective_settings_supported,
						effective_per_app_supported,
						effective_oobe_priority,
						ops ? ops->has_web_ui : false,
						ops ? ops->has_action_script : false,
						ops ? ops->action_supported : false,
						ops && ops->set_enabled,
						abk_control_ops_enabled(ops));
		if (ret)
			goto unlock_err;
	}

	list_for_each_entry(registration, &abk_control_registry, node) {
		const struct abk_control_ops *ops = registration->ops;

		if (!ops || !ops->id || abk_control_manifest_has_id(ops->id))
			continue;
		if (!abk_control_should_expose_extension_module("module",
								ops->extension_id))
			continue;

		ret = abk_control_append_module(&buf, &extension_first,
						ops->id,
						ops->name,
						ops->version,
						ops->description,
						"",
						"runtime",
						"module",
						ops->extension_id,
						ops->companion_package,
						ops->companion_display_name,
						ops->companion_asset_name,
						ops->companion_download_url,
						ops->service_activity,
						"",
						"",
						"",
						"",
						"",
						"abk",
						ops->module_dir,
						ops->web_root,
						ops->requires_companion_app,
						ops->settings_supported,
						ops->per_app_supported,
						ops->oobe_priority,
						ops->has_web_ui,
						ops->has_action_script,
						ops->action_supported,
						ops->set_enabled != NULL,
						abk_control_ops_enabled(ops));
		if (ret)
			goto unlock_err;
	}

	mutex_unlock(&abk_control_lock);

	ret = abk_control_buf_append(&buf, "\n  ]\n}\n");
	if (ret)
		goto err;

	*out = buf.data;
	*out_len = buf.len;
	return 0;

unlock_err:
	mutex_unlock(&abk_control_lock);
err:
	kfree(buf.data);
	return ret;
}

int abk_control_register(const struct abk_control_ops *ops)
{
	struct abk_control_registration *registration;
	int ret = 0;

	if (!ops || !ops->id || !ops->id[0])
		return -EINVAL;

	registration = kzalloc(sizeof(*registration), GFP_KERNEL);
	if (!registration)
		return -ENOMEM;

	mutex_lock(&abk_control_lock);
	if (abk_control_find_locked(ops->id)) {
		ret = -EEXIST;
		goto out;
	}

	registration->ops = ops;
	list_add_tail(&registration->node, &abk_control_registry);
	registration = NULL;

out:
	mutex_unlock(&abk_control_lock);
	kfree(registration);
	return ret;
}
EXPORT_SYMBOL_GPL(abk_control_register);

void abk_control_unregister(const struct abk_control_ops *ops)
{
	struct abk_control_registration *registration;
	struct abk_control_registration *next;

	if (!ops)
		return;

	mutex_lock(&abk_control_lock);
	list_for_each_entry_safe(registration, next, &abk_control_registry, node) {
		if (registration->ops == ops) {
			list_del(&registration->node);
			kfree(registration);
			break;
		}
	}
	mutex_unlock(&abk_control_lock);
}
EXPORT_SYMBOL_GPL(abk_control_unregister);

int abk_control_get_status_json(char **out, size_t *out_len)
{
	if (!out || !out_len)
		return -EINVAL;

	return abk_control_build_status(out, out_len);
}
EXPORT_SYMBOL_GPL(abk_control_get_status_json);

static int abk_control_set_enabled(const char *id, bool enabled)
{
	const struct abk_control_ops *ops;
	int ret;

	mutex_lock(&abk_control_lock);
	ops = abk_control_find_locked(id);
	if (!ops) {
		ret = abk_control_manifest_has_id(id) ? -EOPNOTSUPP : -ENOENT;
		goto out;
	}

	if (!ops->set_enabled) {
		ret = -EOPNOTSUPP;
		goto out;
	}

	ret = ops->set_enabled(enabled, ops->data);

out:
	mutex_unlock(&abk_control_lock);
	return ret;
}

static int abk_control_status_command(const char *id)
{
	int ret = 0;

	mutex_lock(&abk_control_lock);
	if (!abk_control_find_locked(id) && !abk_control_manifest_has_id(id))
		ret = -ENOENT;
	mutex_unlock(&abk_control_lock);

	return ret;
}

static int abk_control_module_command(const char *id, const char *payload)
{
	const struct abk_control_ops *ops;
	int ret;

	mutex_lock(&abk_control_lock);
	ops = abk_control_find_locked(id);
	if (!ops) {
		ret = abk_control_manifest_has_id(id) ? -EOPNOTSUPP : -ENOENT;
		goto out;
	}

	if (!ops->run_command) {
		ret = -EOPNOTSUPP;
		goto out;
	}

	ret = ops->run_command(payload, ops->data);

out:
	mutex_unlock(&abk_control_lock);
	return ret;
}

int abk_control_run_command(const char *input, size_t count)
{
	char command[ABK_CONTROL_MAX_COMMAND];
	char *cursor;
	char *verb;
	char *id;
	char *payload;
	size_t len;
	int ret;

	if (!input)
		return -EINVAL;

	len = min(count, sizeof(command) - 1);
	if (!len)
		return -EINVAL;

	memcpy(command, input, len);
	command[len] = '\0';

	cursor = strim(command);
	verb = strsep(&cursor, " \t\r\n");
	id = strsep(&cursor, " \t\r\n");
	id = strim(id ? id : "");
	payload = strim(cursor ? cursor : "");

	if (!verb || !verb[0] || !id[0])
		return -EINVAL;

	if (!strcmp(verb, "enable"))
		ret = abk_control_set_enabled(id, true);
	else if (!strcmp(verb, "disable"))
		ret = abk_control_set_enabled(id, false);
	else if (!strcmp(verb, "status"))
		ret = abk_control_status_command(id);
	else if (!strcmp(verb, "command"))
		ret = abk_control_module_command(id, payload);
	else
		ret = -EINVAL;

	return ret;
}
EXPORT_SYMBOL_GPL(abk_control_run_command);

static int __init abk_control_init(void)
{
	return 0;
}

static void __exit abk_control_exit(void)
{
}

module_init(abk_control_init);
module_exit(abk_control_exit);

MODULE_DESCRIPTION("ABK external module metadata and control interface");
MODULE_LICENSE("GPL");
