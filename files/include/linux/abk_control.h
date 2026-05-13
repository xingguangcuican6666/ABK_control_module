/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _LINUX_ABK_CONTROL_H
#define _LINUX_ABK_CONTROL_H

#include <linux/types.h>

struct abk_control_manifest_entry {
	const char *id;
	const char *name;
	const char *version;
	const char *description;
	const char *repo_url;
	const char *stage;
};

struct abk_control_ops {
	const char *id;
	const char *name;
	const char *version;
	const char *description;
	bool (*is_enabled)(void *data);
	int (*set_enabled)(bool enabled, void *data);
	void *data;
};

int abk_control_register(const struct abk_control_ops *ops);
void abk_control_unregister(const struct abk_control_ops *ops);

extern const struct abk_control_manifest_entry abk_control_manifest[];
extern const size_t abk_control_manifest_count;

#endif /* _LINUX_ABK_CONTROL_H */
