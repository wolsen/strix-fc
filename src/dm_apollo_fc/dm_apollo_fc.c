/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Apollo FC device-mapper target glue.
 *
 * The target name is exposed as "apollo_fc" and implements a minimal linear
 * remap of bios to a single backing device. It is used by higher-level Apollo
 * FC control flows when an explicit DM mapping object is preferred over direct
 * device node usage.
 */
#include <linux/module.h>
#include <linux/device-mapper.h>
#include <linux/blkdev.h>
#include <linux/slab.h>

#include "apollo_fc_compat.h"

struct apollo_fc_dm_c {
/*
 * struct apollo_fc_dm_c - Per-target-instance context.
 * @dev: Backing device obtained via dm_get_device().
 */
	struct dm_dev *dev;
};

/*
 * apollo_fc_dm_ctr() - Construct one DM target instance.
 * @ti: Target instance descriptor.
 * @argc: Number of target arguments (must be 1).
 * @argv: Argument vector; argv[0] is backing path or major:minor.
 */
static int apollo_fc_dm_ctr(struct dm_target *ti, unsigned int argc, char **argv)
{
	struct apollo_fc_dm_c *ctx;
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

static void apollo_fc_dm_dtr(struct dm_target *ti)
{
	struct apollo_fc_dm_c *ctx = ti->private;

	if (!ctx)
		return;

	if (ctx->dev)
		dm_put_device(ti, ctx->dev);
	kfree(ctx);
}

/*
 * apollo_fc_dm_map() - Remap incoming bio to backing block device.
 *
 * Returns DM_MAPIO_REMAPPED on success or DM_MAPIO_KILL if the target has no
 * valid backing device.
 */
static int apollo_fc_dm_map(struct dm_target *ti, struct bio *bio)
{
	struct apollo_fc_dm_c *ctx = ti->private;

	if (!ctx || !ctx->dev || !ctx->dev->bdev)
		return DM_MAPIO_KILL;

	bio_set_dev(bio, ctx->dev->bdev);
	return DM_MAPIO_REMAPPED;
}

static void apollo_fc_dm_status(struct dm_target *ti, status_type_t type,
				unsigned int status_flags, char *result, unsigned int maxlen)
{
	struct apollo_fc_dm_c *ctx = ti->private;
	unsigned int sz = 0;

	if (type == STATUSTYPE_INFO) {
		DMEMIT("apollo_fc");
		return;
	}

	if (!ctx || !ctx->dev)
		DMEMIT("-");
	else
		DMEMIT("%s", ctx->dev->name);
}

static int apollo_fc_dm_iterate_devices(struct dm_target *ti,
					iterate_devices_callout_fn fn, void *data)
{
	struct apollo_fc_dm_c *ctx = ti->private;

	if (ctx && ctx->dev)
		return fn(ti, ctx->dev, 0, ti->len, data);

	return 0;
}

/* Device-mapper target type registration record. */
static struct target_type apollo_fc_target = {
	.name = APOLLO_FC_DM_TARGET_NAME,
	.version = {1, 0, 0},
	.module = THIS_MODULE,
	.ctr = apollo_fc_dm_ctr,
	.dtr = apollo_fc_dm_dtr,
	.map = apollo_fc_dm_map,
	.status = apollo_fc_dm_status,
	.iterate_devices = apollo_fc_dm_iterate_devices,
};

static int __init apollo_fc_dm_init(void)
{
	int ret = dm_register_target(&apollo_fc_target);

	if (ret) {
		pr_err("dm_apollo_fc: failed to register target: %d\n", ret);
		return ret;
	}

	pr_info("dm_apollo_fc: registered target '%s'\n", APOLLO_FC_DM_TARGET_NAME);
	return 0;
}

static void __exit apollo_fc_dm_exit(void)
{
	dm_unregister_target(&apollo_fc_target);
	pr_info("dm_apollo_fc: unregistered\n");
}

module_init(apollo_fc_dm_init);
module_exit(apollo_fc_dm_exit);

MODULE_DESCRIPTION("Apollo fake FC DM target");
MODULE_AUTHOR("Lunacy Systems");
MODULE_LICENSE("GPL");