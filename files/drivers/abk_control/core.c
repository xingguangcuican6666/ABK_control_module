// SPDX-License-Identifier: GPL-2.0
#include <linux/abk_control.h>
#include <linux/errno.h>
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/list.h>
#include <linux/miscdevice.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/string.h>
#include <linux/uaccess.h>

#define ABK_CONTROL_DEVICE_NAME "abk_control"
#define ABK_CONTROL_INITIAL_BUFFER 1024
#define ABK_CONTROL_MAX_WRITE 160

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

static int abk_control_append_manager_info(struct abk_control_buffer *buf)
{
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
	return abk_control_buf_append(buf,
				      "    \"capabilities\": [\"build\", \"modules\", \"abk_control\"]\n"
				      "  },\n");
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

static int abk_control_append_module(struct abk_control_buffer *buf,
				     bool *first,
				     const char *id,
				     const char *name,
				     const char *version,
				     const char *description,
				     const char *repo_url,
				     const char *stage,
				     const char *source,
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
	ABK_JSON_FIELD("source", source);

#undef ABK_JSON_FIELD

	ret = abk_control_buf_appendf(buf,
				     "\"controllable\": %s, \"enabled\": %s}",
				     controllable ? "true" : "false",
				     enabled ? "true" : "false");
	return ret;
}

static int abk_control_build_status(char **out, size_t *out_len)
{
	struct abk_control_registration *registration;
	struct abk_control_buffer buf = {};
	bool first = true;
	size_t i;
	int ret;

	ret = abk_control_buf_append(&buf, "{\n  \"schema\": 3,\n");
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
						"abk",
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
						"abk",
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

static ssize_t abk_control_read(struct file *file, char __user *user_buf,
				size_t count, loff_t *ppos)
{
	char *status;
	size_t status_len;
	ssize_t ret;

	ret = abk_control_build_status(&status, &status_len);
	if (ret)
		return ret;

	ret = simple_read_from_buffer(user_buf, count, ppos, status, status_len);
	kfree(status);
	return ret;
}

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

static ssize_t abk_control_write(struct file *file, const char __user *user_buf,
				 size_t count, loff_t *ppos)
{
	char command[ABK_CONTROL_MAX_WRITE];
	char *cursor;
	char *verb;
	char *id;
	size_t len;
	int ret;

	len = min(count, sizeof(command) - 1);
	if (copy_from_user(command, user_buf, len))
		return -EFAULT;
	command[len] = '\0';

	cursor = strim(command);
	verb = strsep(&cursor, " \t\r\n");
	id = strim(cursor ? cursor : "");

	if (!verb || !verb[0] || !id[0])
		return -EINVAL;

	if (!strcmp(verb, "enable"))
		ret = abk_control_set_enabled(id, true);
	else if (!strcmp(verb, "disable"))
		ret = abk_control_set_enabled(id, false);
	else if (!strcmp(verb, "status"))
		ret = abk_control_status_command(id);
	else
		ret = -EINVAL;

	return ret ? ret : count;
}

static const struct file_operations abk_control_fops = {
	.owner = THIS_MODULE,
	.read = abk_control_read,
	.write = abk_control_write,
	.llseek = default_llseek,
};

static struct miscdevice abk_control_device = {
	.minor = MISC_DYNAMIC_MINOR,
	.name = ABK_CONTROL_DEVICE_NAME,
	.fops = &abk_control_fops,
	.mode = 0600,
};

static int __init abk_control_init(void)
{
	return misc_register(&abk_control_device);
}

static void __exit abk_control_exit(void)
{
	misc_deregister(&abk_control_device);
}

module_init(abk_control_init);
module_exit(abk_control_exit);

MODULE_DESCRIPTION("ABK external module metadata and control interface");
MODULE_LICENSE("GPL");
