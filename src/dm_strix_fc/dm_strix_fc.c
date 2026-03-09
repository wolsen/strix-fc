/* SPDX-FileCopyrightText: 2026 Canonical, Ltd. */
/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Strix FC device-mapper target glue.
 *
 * The target name is exposed as "strix_fc" and implements a minimal linear
 * remap of bios to a single backing device. It is used by higher-level Apollo
 * FC control flows when an explicit DM mapping object is preferred over direct
 * device node usage.
 */
#include <linux/module.h>
#include <linux/device-mapper.h>
#include <linux/blkdev.h>
#include <linux/slab.h>

#include "strix_fc_compat.h"

struct strix_fc_dm_c {
/*
 * struct strix_fc_dm_c - Per-target-instance context.
 * @dev: Backing device obtained via dm_get_device().
 */
	struct dm_dev *dev;
};

/*
 * strix_fc_dm_ctr() - Construct one DM target instance.
 * @ti: Target instance descriptor.
 * @argc: Number of target arguments (must be 1).
 * @argv: Argument vector; argv[0] is backing path or major:minor.
 */
static int strix_fc_dm_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
	struct strix_fc_dm_c *ctx;
	int ret;

	if (argc != 1) {
		ti->error = "Invalid argument count; expected <major:minor|path>";
		return -EINVAL;
	}

	ctx = kzalloc(sizeof(*ctx), GFP_KERNEL);
	if (!ctx)
		return -ENOMEM;

	ret = dm_get_device(ti, argv[0], dm_table_get_mode(ti->table), &ctx->dev);
	if (ret) {
		ti->error = "Failed to open backing device";
		kfree(ctx);
		return ret;
	}

	ti->private = ctx;
	return 0;
}

static void strix_fc_dm_dtr(struct dm_target *ti)
{
	struct strix_fc_dm_c *ctx = ti->private;

	if (!ctx)
		return;

	if (ctx->dev)
		dm_put_device(ti, ctx->dev);
	kfree(ctx);
}

/*
 * strix_fc_dm_map() - Remap incoming bio to backing block device.
 *
 * Returns DM_MAPIO_REMAPPED on success or DM_MAPIO_KILL if the target has no
 * valid backing device.
 */
static int strix_fc_dm_map(struct dm_target *ti, struct bio *bio)
{
	struct strix_fc_dm_c *ctx = ti->private;

	if (!ctx || !ctx->dev || !ctx->dev->bdev)
		return DM_MAPIO_KILL;

	bio_set_dev(bio, ctx->dev->bdev);
	return DM_MAPIO_REMAPPED;
}

static void strix_fc_dm_status(struct dm_target *ti, status_type_t type,
				unsigned int status_flags, char *result, unsigned int maxlen)
{
	struct strix_fc_dm_c *ctx = ti->private;
	unsigned int sz = 0;

	if (type == STATUSTYPE_INFO) {
		DMEMIT("strix_fc");
		return;
	}

	if (!ctx || !ctx->dev)
		DMEMIT("-");
	else
		DMEMIT("%s", ctx->dev->name);
}

static int strix_fc_dm_iterate_devices(struct dm_target *ti,
					iterate_devices_callout_fn fn, void *data)
{
	struct strix_fc_dm_c *ctx = ti->private;

	if (ctx && ctx->dev)
		return fn(ti, ctx->dev, 0, ti->len, data);

	return 0;
}

/* Device-mapper target type registration record. */
static struct target_type strix_fc_target = {
	.name = STRIX_FC_DM_TARGET_NAME,
	.version = {1, 0, 0},
	.module = THIS_MODULE,
	.ctr = strix_fc_dm_ctr,
	.dtr = strix_fc_dm_dtr,
	.map = strix_fc_dm_map,
	.status = strix_fc_dm_status,
	.iterate_devices = strix_fc_dm_iterate_devices,
};

static int __init strix_fc_dm_init(void)
{
	int ret = dm_register_target(&strix_fc_target);

	if (ret) {
		pr_err("dm_strix_fc: failed to register target: %d\n", ret);
		return ret;
	}

	pr_info("dm_strix_fc: registered target '%s'\n", STRIX_FC_DM_TARGET_NAME);
	return 0;
}

static void __exit strix_fc_dm_exit(void)
{
	dm_unregister_target(&strix_fc_target);
	pr_info("dm_strix_fc: unregistered\n");
}

module_init(strix_fc_dm_init);
module_exit(strix_fc_dm_exit);

MODULE_DESCRIPTION("Apollo fake FC DM target");
MODULE_AUTHOR("Lunacy Systems");
MODULE_LICENSE("GPL");