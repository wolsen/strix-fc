/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Apollo Fake Fibre Channel core module
 *
 * This module emulates an FC transport topology (host -> rports -> LUNs)
 * entirely in-kernel so userspace stacks that expect FC semantics can run on
 * hosts without physical FC HBAs.
 *
 * High-level model:
 * - One virtual FC initiator host is created at module load.
 * - Userspace configures target rports and LUN->backing-device mappings via
 *   Generic Netlink.
 * - SCSI commands are translated to block I/O against mapped backing devices.
 *
 * Concurrency model:
 * - Global topology list protected by apollo_hosts_lock.
 * - Per-host mutable state (rports/luns) protected by host->lock.
 * - Lock ordering is strict: apollo_hosts_lock -> host->lock.
 */
#include <linux/module.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/list.h>
#include <linux/netlink.h>
#include <linux/blkdev.h>
#include <linux/bio.h>
#include <linux/scatterlist.h>
#include <linux/string.h>
#include <linux/refcount.h>

#include <net/genetlink.h>

#include <scsi/scsi.h>
#include <scsi/scsi_cmnd.h>
#include <scsi/scsi_device.h>
#include <scsi/scsi_host.h>
#include <scsi/scsi_transport_fc.h>

#include "apollo_fc_compat.h"

/* Generic Netlink command identifiers for the apollo_fc control plane. */
enum apollo_fc_cmd {
	APOLLO_FC_CMD_UNSPEC,
	APOLLO_FC_CMD_CREATE_RPORT,
	APOLLO_FC_CMD_DELETE_RPORT,
	APOLLO_FC_CMD_MAP_LUN,
	APOLLO_FC_CMD_UNMAP_LUN,
	APOLLO_FC_CMD_LIST_STATE,
	__APOLLO_FC_CMD_MAX,
};

#define APOLLO_FC_CMD_MAX (__APOLLO_FC_CMD_MAX - 1)

/* Generic Netlink attributes accepted/emitted by apollo_fc commands. */
enum apollo_fc_attr {
	APOLLO_FC_A_UNSPEC,
	APOLLO_FC_A_HOST_ID,
	APOLLO_FC_A_TARGET_WWPN,
	APOLLO_FC_A_TARGET_NODE_WWPN,
	APOLLO_FC_A_LUN_ID,
	APOLLO_FC_A_BACKING_MAJOR,
	APOLLO_FC_A_BACKING_MINOR,
	APOLLO_FC_A_DM_NAME,
	APOLLO_FC_A_STATE_TEXT,
	__APOLLO_FC_A_MAX,
};

#define APOLLO_FC_A_MAX (__APOLLO_FC_A_MAX - 1)

struct apollo_fc_lun_map {
/*
 * struct apollo_fc_lun_map - One exported FC LUN mapped to a backing block dev.
 * @lun_id: SCSI logical unit number exposed under an rport.
 * @devt: Backing block device major/minor.
 * @bdev_handle: Lifetime-managed block device open handle.
 * @bdev: Convenience pointer to @bdev_handle->bdev.
 * @dm_name: Optional device-mapper name hint for observability.
 * @sdev: SCSI device instance when discovered by the SCSI midlayer.
 */
	struct list_head node;
	u64 lun_id;
	dev_t devt;
	struct bdev_handle *bdev_handle;
	struct block_device *bdev;
	char dm_name[64];
	struct scsi_device *sdev;
	refcount_t refs;
};

struct apollo_fc_rport {
/*
 * struct apollo_fc_rport - Emulated remote FC target port.
 * @target_wwpn: Target port WWPN.
 * @target_node_wwpn: Target node WWPN.
 * @channel: Exposed SCSI channel (currently fixed to 0).
 * @target_id: Stable SCSI target id allocated from host->next_target_id.
 * @fc_rport: Transport-class rport object owned by FC transport.
 * @luns: List of struct apollo_fc_lun_map entries.
 */
	struct list_head node;
	u64 target_wwpn;
	u64 target_node_wwpn;
	u32 channel;
	u32 target_id;
	struct fc_rport *fc_rport;
	struct list_head luns;
};

struct apollo_fc_host {
/*
 * struct apollo_fc_host - Per-initiator-host state for Apollo FC.
 * @host_id: SCSI host number visible to userspace.
 * @shost: Backing Scsi_Host instance.
 * @lock: Protects mutable per-host topology state.
 * @next_target_id: Monotonic target id allocator for new rports.
 * @rports: List of configured remote ports.
 */
	struct list_head node;
	u32 host_id;
	struct Scsi_Host *shost;
	struct mutex lock;
	u32 next_target_id;
	struct list_head rports;
};

static LIST_HEAD(apollo_hosts);
static DEFINE_MUTEX(apollo_hosts_lock);
static struct scsi_transport_template *apollo_fc_transport;

static u64 initiator_wwpn = 0x500a09c0ffe00001ULL;
module_param(initiator_wwpn, ullong, 0644);
MODULE_PARM_DESC(initiator_wwpn, "Initial host port_name WWPN");

static u64 initiator_node_wwpn = 0x500a09c0ffe0aa01ULL;
module_param(initiator_node_wwpn, ullong, 0644);
MODULE_PARM_DESC(initiator_node_wwpn, "Initial host node_name WWPN");

static struct apollo_fc_host *apollo_host_from_shost(struct Scsi_Host *shost)
{
	return *(struct apollo_fc_host **)shost_priv(shost);
}

static struct apollo_fc_host *apollo_find_host_by_id(u32 host_id)
{
	struct apollo_fc_host *host;

	list_for_each_entry(host, &apollo_hosts, node) {
		if (host->host_id == host_id)
			return host;
	}

	return NULL;
}

static struct apollo_fc_rport *apollo_find_rport_by_wwpn(struct apollo_fc_host *host,
			u64 target_wwpn)
{
	struct apollo_fc_rport *rport;

	list_for_each_entry(rport, &host->rports, node) {
		if (rport->target_wwpn == target_wwpn)
			return rport;
	}

	return NULL;
}

static struct apollo_fc_lun_map *apollo_find_lun_map(struct apollo_fc_rport *rport,
		u64 lun_id)
{
	struct apollo_fc_lun_map *map;

	list_for_each_entry(map, &rport->luns, node) {
		if (map->lun_id == lun_id)
			return map;
	}

	return NULL;
}

static void apollo_lun_map_get(struct apollo_fc_lun_map *map)
{
	refcount_inc(&map->refs);
}

static void apollo_lun_map_put(struct apollo_fc_lun_map *map)
{
	if (!refcount_dec_and_test(&map->refs))
		return;

	if (map->bdev_handle)
		bdev_release(map->bdev_handle);
	kfree(map);
}

static bool apollo_lun_matches(u64 configured_lun, u64 scsi_lun)
{
	if (configured_lun == scsi_lun)
		return true;

	if (configured_lun <= 0xffULL && (scsi_lun & 0xffULL) == configured_lun)
		return true;

	return false;
}

static struct apollo_fc_lun_map *apollo_find_lun_map_by_scsi(struct apollo_fc_host *host,
		u32 channel, u32 target_id, u64 lun)
{
	struct apollo_fc_rport *rport;
	struct apollo_fc_lun_map *map;

	list_for_each_entry(rport, &host->rports, node) {
		if (rport->channel != channel || rport->target_id != target_id)
			continue;
		list_for_each_entry(map, &rport->luns, node) {
			if (apollo_lun_matches(map->lun_id, lun))
				return map;
		}
		return NULL;
	}

	return NULL;
}

static void apollo_scsi_complete(struct scsi_cmnd *scmd, int result);

struct apollo_fc_io_ctx {
	struct scsi_cmnd *scmd;
	struct apollo_fc_lun_map *map;
};

static void apollo_scsi_bio_end_io(struct bio *bio)
{
	struct apollo_fc_io_ctx *ctx = bio->bi_private;
	int result;

	result = (bio->bi_status == BLK_STS_OK) ? (DID_OK << 16) : (DID_ERROR << 16);
	bio_put(bio);
	apollo_lun_map_put(ctx->map);
	apollo_scsi_complete(ctx->scmd, result);
	kfree(ctx);
}

static int apollo_scsi_submit_rw(struct apollo_fc_lun_map *map, struct scsi_cmnd *scmd,
			u64 lba, u32 blocks, bool write, bool fua)
{
	struct scatterlist *sg;
	struct bio *bio;
	struct apollo_fc_io_ctx *ctx;
	unsigned int i;
	blk_opf_t opf;

	if (!blocks)
		return 0;

	ctx = kzalloc(sizeof(*ctx), GFP_ATOMIC);
	if (!ctx)
		return -ENOMEM;

	ctx->scmd = scmd;
	ctx->map = map;

	opf = write ? REQ_OP_WRITE : REQ_OP_READ;

	bio = bio_alloc(map->bdev, scsi_sg_count(scmd), opf, GFP_ATOMIC);
	if (!bio) {
		kfree(ctx);
		return -ENOMEM;
	}

	bio->bi_iter.bi_sector = lba;
	bio->bi_private = ctx;
	bio->bi_end_io = apollo_scsi_bio_end_io;
	if (fua)
		bio->bi_opf |= REQ_FUA;

	scsi_for_each_sg(scmd, sg, scsi_sg_count(scmd), i) {
		if (!bio_add_page(bio, sg_page(sg), sg->length, sg->offset)) {
			bio_put(bio);
			kfree(ctx);
			return -EIO;
		}
	}

	submit_bio(bio);

	return 1;
}

/*
 * apollo_scsi_emulate_report_luns() - Build REPORT LUNS payload for one rport.
 * @host: Owning host (currently informational; state comes from @rport).
 * @scmd: Incoming SCSI command to populate.
 * @rport: Target rport whose configured LUNs are advertised.
 *
 * Returns 0 on success or a negative errno if payload copy fails.
 */
static int apollo_scsi_emulate_report_luns(struct apollo_fc_host *host,
		struct scsi_cmnd *scmd, struct apollo_fc_rport *rport)
{
	u8 buf[512] = {0};
	struct apollo_fc_lun_map *map;
	u32 count = 0;
	u32 payload_len;
	int copied;

	list_for_each_entry(map, &rport->luns, node) {
		u32 off = 8 + (count * 8);

		if (off + 8 > sizeof(buf))
			break;

		buf[off] = 0;
		buf[off + 1] = (u8)(map->lun_id & 0xff);
		count++;
	}

	payload_len = count * 8;
	apollo_fc_put_unaligned_be32(payload_len, buf);

	copied = sg_copy_from_buffer(scsi_sglist(scmd), scsi_sg_count(scmd),
				     buf, min_t(u32, sizeof(buf), scsi_bufflen(scmd)));

	if (copied <= 0)
		return -EIO;

	return 0;
}

static void apollo_scsi_complete(struct scsi_cmnd *scmd, int result)
{
	scmd->result = result;
	scsi_done(scmd);
}

/*
 * apollo_queuecommand() - Main SCSI data path entrypoint.
 * @shost: Virtual SCSI host receiving the command.
 * @scmd: SCSI command descriptor from the midlayer.
 *
 * This handler resolves channel/target/lun to a configured map, emulates a
 * small command set required for FC discovery and block I/O, then completes
 * the command synchronously.
 *
 * Supported commands include INQUIRY, REPORT_LUNS, READ/WRITE(10/16),
 * READ_CAPACITY(10/16), and SYNCHRONIZE_CACHE.
 */
static int apollo_queuecommand(struct Scsi_Host *shost, struct scsi_cmnd *scmd)
{
	struct apollo_fc_host *host = apollo_host_from_shost(shost);
	struct apollo_fc_lun_map *map = NULL;
	struct apollo_fc_rport *rport = NULL;
	u8 *cdb = scmd->cmnd;
	u8 op = cdb[0];
	int ret = 0;
	u8 inq[96] = {0};
	u8 cap10[8] = {0};
	u8 cap16[32] = {0};
	u64 lba;
	u32 blocks;
	sector_t sectors;
	struct apollo_fc_rport *iter;
	bool is_lun0;
	bool map_ref_held = false;
	bool completed_async = false;

	if (!host) {
		apollo_scsi_complete(scmd, DID_NO_CONNECT << 16);
		return 0;
	}

	mutex_lock(&host->lock);
	map = apollo_find_lun_map_by_scsi(host, scmd->device->channel,
					 scmd->device->id, scmd->device->lun);
	is_lun0 = (scmd->device->lun == 0);

	list_for_each_entry(iter, &host->rports, node) {
		if (iter->channel == scmd->device->channel && iter->target_id == scmd->device->id) {
			rport = iter;
			break;
		}
	}

	if (!map) {
		bool allow_discovery_probe;

		allow_discovery_probe = is_lun0 && (op == INQUIRY || op == TEST_UNIT_READY);

		if (!(op == REPORT_LUNS || allow_discovery_probe)) {
			mutex_unlock(&host->lock);
			apollo_scsi_complete(scmd, DID_NO_CONNECT << 16);
			return 0;
		}
	} else {
		apollo_lun_map_get(map);
		map_ref_held = true;
	}

	if (op == REPORT_LUNS) {
		if (!rport)
			ret = -ENODEV;
		else
			ret = apollo_scsi_emulate_report_luns(host, scmd, rport);
		mutex_unlock(&host->lock);
		goto complete;
	}

	mutex_unlock(&host->lock);

	switch (op) {
	case TEST_UNIT_READY:
		ret = 0;
		break;
	case INQUIRY:
		inq[0] = TYPE_DISK;
		inq[2] = 0x06;
		inq[3] = 0x02;
		inq[4] = 31;
		memcpy(&inq[8], "LUNACY  ", 8);
		memcpy(&inq[16], "APOLLO FC LUN   ", 16);
		memcpy(&inq[32], "0001", 4);
		if (sg_copy_from_buffer(scsi_sglist(scmd), scsi_sg_count(scmd),
					inq, min_t(u32, sizeof(inq), scsi_bufflen(scmd))) <= 0)
			ret = -EIO;
		break;
	case READ_CAPACITY:
		if (!map) {
			ret = -ENODEV;
			break;
		}
		sectors = bdev_nr_sectors(map->bdev);
		if (sectors == 0)
			sectors = 1;
		if (sectors - 1 > U32_MAX)
			apollo_fc_put_unaligned_be32(U32_MAX, cap10);
		else
			apollo_fc_put_unaligned_be32((u32)(sectors - 1), cap10);
		apollo_fc_put_unaligned_be32(512, &cap10[4]);
		if (sg_copy_from_buffer(scsi_sglist(scmd), scsi_sg_count(scmd), cap10,
					sizeof(cap10)) <= 0)
			ret = -EIO;
		break;
	case SERVICE_ACTION_IN_16:
		if ((cdb[1] & 0x1f) != SAI_READ_CAPACITY_16) {
			ret = -EINVAL;
			break;
		}
		if (!map) {
			ret = -ENODEV;
			break;
		}
		sectors = bdev_nr_sectors(map->bdev);
		if (sectors == 0)
			sectors = 1;
		apollo_fc_put_unaligned_be64((u64)(sectors - 1), cap16);
		apollo_fc_put_unaligned_be32(512, &cap16[8]);
		if (sg_copy_from_buffer(scsi_sglist(scmd), scsi_sg_count(scmd), cap16,
					sizeof(cap16)) <= 0)
			ret = -EIO;
		break;
	case SYNCHRONIZE_CACHE:
		if (!map) {
			ret = -ENODEV;
			break;
		}
		ret = blkdev_issue_flush(map->bdev);
		break;
	case READ_10:
		if (!map) {
			ret = -ENODEV;
			break;
		}
		lba = apollo_fc_get_unaligned_be32(&cdb[2]);
		blocks = ((u16)cdb[7] << 8) | cdb[8];
		ret = apollo_scsi_submit_rw(map, scmd, lba, blocks ? blocks : 65536,
					false, false);
		if (ret == 1) {
			completed_async = true;
			map_ref_held = false;
		}
		break;
	case WRITE_10:
		if (!map) {
			ret = -ENODEV;
			break;
		}
		lba = apollo_fc_get_unaligned_be32(&cdb[2]);
		blocks = ((u16)cdb[7] << 8) | cdb[8];
		ret = apollo_scsi_submit_rw(map, scmd, lba, blocks ? blocks : 65536,
					true, !!(cdb[1] & 0x8));
		if (ret == 1) {
			completed_async = true;
			map_ref_held = false;
		}
		break;
	case READ_16:
		if (!map) {
			ret = -ENODEV;
			break;
		}
		lba = apollo_fc_get_unaligned_be64(&cdb[2]);
		blocks = apollo_fc_get_unaligned_be32(&cdb[10]);
		ret = apollo_scsi_submit_rw(map, scmd, lba, blocks, false, false);
		if (ret == 1) {
			completed_async = true;
			map_ref_held = false;
		}
		break;
	case WRITE_16:
		if (!map) {
			ret = -ENODEV;
			break;
		}
		lba = apollo_fc_get_unaligned_be64(&cdb[2]);
		blocks = apollo_fc_get_unaligned_be32(&cdb[10]);
		ret = apollo_scsi_submit_rw(map, scmd, lba, blocks, true, !!(cdb[1] & 0x8));
		if (ret == 1) {
			completed_async = true;
			map_ref_held = false;
		}
		break;
	default:
		ret = -EOPNOTSUPP;
		break;
	}

complete:
	if (map_ref_held)
		apollo_lun_map_put(map);

	if (completed_async)
		return 0;

	if (ret)
		apollo_scsi_complete(scmd, DID_ERROR << 16);
	else
		apollo_scsi_complete(scmd, DID_OK << 16);

	return 0;
}

static int apollo_slave_configure(struct scsi_device *sdev)
{
	struct apollo_fc_host *host = apollo_host_from_shost(sdev->host);
	struct apollo_fc_lun_map *map;

	if (!host)
		return -ENODEV;

	mutex_lock(&host->lock);
	map = apollo_find_lun_map_by_scsi(host, sdev->channel, sdev->id, sdev->lun);
	if (map)
		map->sdev = sdev;
	mutex_unlock(&host->lock);

	blk_queue_logical_block_size(sdev->request_queue, 512);
	return 0;
}

static void apollo_slave_destroy(struct scsi_device *sdev)
{
	struct apollo_fc_host *host = apollo_host_from_shost(sdev->host);
	struct apollo_fc_rport *rport;
	struct apollo_fc_lun_map *map;

	if (!host)
		return;

	mutex_lock(&host->lock);
	list_for_each_entry(rport, &host->rports, node) {
		list_for_each_entry(map, &rport->luns, node) {
			if (map->sdev == sdev)
				map->sdev = NULL;
		}
	}
	mutex_unlock(&host->lock);
}

static struct scsi_host_template apollo_sht = {
	.module = THIS_MODULE,
	.name = "apollo_fc",
	.proc_name = "apollo_fc",
	.queuecommand = apollo_queuecommand,
	.slave_configure = apollo_slave_configure,
	.slave_destroy = apollo_slave_destroy,
	.this_id = -1,
	.sg_tablesize = SG_ALL,
	.can_queue = 128,
	.cmd_per_lun = 64,
	.max_sectors = 2048,
};

/* Attributes exported by FC transport class into sysfs for host/rport objects. */
static struct fc_function_template apollo_fc_function_template = {
	.show_host_node_name = 1,
	.show_host_port_name = 1,
	.show_host_supported_classes = 1,
	.show_host_port_id = 1,
	.show_host_speed = 1,
	.show_host_port_state = 1,
	.show_rport_dev_loss_tmo = 1,
};

/* Input validation policy for Generic Netlink attributes. */
static const struct nla_policy apollo_fc_genl_policy[APOLLO_FC_A_MAX + 1] = {
	[APOLLO_FC_A_HOST_ID] = {.type = NLA_U32},
	[APOLLO_FC_A_TARGET_WWPN] = {.type = NLA_U64},
	[APOLLO_FC_A_TARGET_NODE_WWPN] = {.type = NLA_U64},
	[APOLLO_FC_A_LUN_ID] = {.type = NLA_U64},
	[APOLLO_FC_A_BACKING_MAJOR] = {.type = NLA_U32},
	[APOLLO_FC_A_BACKING_MINOR] = {.type = NLA_U32},
	[APOLLO_FC_A_DM_NAME] = {.type = NLA_NUL_STRING, .len = 63},
};

/*
 * apollo_genl_reply_state() - Emit text topology snapshot via LIST_STATE reply.
 * @info: Netlink request metadata used for reply addressing.
 * @host_filter: Specific host id or U32_MAX for all hosts.
 */
static int apollo_genl_reply_state(struct genl_info *info, u32 host_filter)
{
	struct sk_buff *skb;
	void *hdr;
	struct apollo_fc_host *host;
	struct apollo_fc_rport *rport;
	struct apollo_fc_lun_map *map;
	char *buf;
	int len = 0;

	buf = kzalloc(PAGE_SIZE * 4, GFP_KERNEL);
	if (!buf)
		return -ENOMEM;

	mutex_lock(&apollo_hosts_lock);
	list_for_each_entry(host, &apollo_hosts, node) {
		if (host_filter != U32_MAX && host_filter != host->host_id)
			continue;
		mutex_lock(&host->lock);
		len += scnprintf(buf + len, (PAGE_SIZE * 4) - len,
			"host=%u initiator=0x%016llx node=0x%016llx\n",
			host->host_id,
			(unsigned long long)fc_host_port_name(host->shost),
			(unsigned long long)fc_host_node_name(host->shost));
		list_for_each_entry(rport, &host->rports, node) {
			len += scnprintf(buf + len, (PAGE_SIZE * 4) - len,
				"  rport target=0x%016llx node=0x%016llx ch=%u id=%u\n",
				(unsigned long long)rport->target_wwpn,
				(unsigned long long)rport->target_node_wwpn,
				rport->channel, rport->target_id);
			list_for_each_entry(map, &rport->luns, node) {
				len += scnprintf(buf + len, (PAGE_SIZE * 4) - len,
					"    lun=%llu backing=%u:%u dm=%s sdev=%s\n",
					(unsigned long long)map->lun_id,
					MAJOR(map->devt), MINOR(map->devt),
					map->dm_name[0] ? map->dm_name : "-",
					map->sdev ? "present" : "missing");
			}
		}
		mutex_unlock(&host->lock);
	}
	mutex_unlock(&apollo_hosts_lock);

	skb = genlmsg_new(NLMSG_GOODSIZE, GFP_KERNEL);
	if (!skb) {
		kfree(buf);
		return -ENOMEM;
	}

	hdr = genlmsg_put_reply(skb, info, NULL, 0, APOLLO_FC_CMD_LIST_STATE);
	if (!hdr) {
		nlmsg_free(skb);
		kfree(buf);
		return -ENOMEM;
	}

	if (nla_put_string(skb, APOLLO_FC_A_STATE_TEXT, buf)) {
		nlmsg_free(skb);
		kfree(buf);
		return -EMSGSIZE;
	}

	genlmsg_end(skb, hdr);
	kfree(buf);
	return genlmsg_reply(skb, info);
}

static int apollo_genl_create_rport(struct sk_buff *skb, struct genl_info *info)
{
	struct apollo_fc_host *host;
	struct apollo_fc_rport *rport;
	struct fc_rport_identifiers ids = {0};
	u32 host_id;
	u64 target_wwpn;
	u64 target_node_wwpn;

	if (!info->attrs[APOLLO_FC_A_HOST_ID] || !info->attrs[APOLLO_FC_A_TARGET_WWPN])
		return -EINVAL;

	host_id = nla_get_u32(info->attrs[APOLLO_FC_A_HOST_ID]);
	target_wwpn = nla_get_u64(info->attrs[APOLLO_FC_A_TARGET_WWPN]);
	target_node_wwpn = info->attrs[APOLLO_FC_A_TARGET_NODE_WWPN] ?
		nla_get_u64(info->attrs[APOLLO_FC_A_TARGET_NODE_WWPN]) : target_wwpn;

	mutex_lock(&apollo_hosts_lock);
	host = apollo_find_host_by_id(host_id);
	if (!host) {
		mutex_unlock(&apollo_hosts_lock);
		return -ENOENT;
	}

	mutex_lock(&host->lock);
	if (apollo_find_rport_by_wwpn(host, target_wwpn)) {
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return 0;
	}

	rport = kzalloc(sizeof(*rport), GFP_KERNEL);
	if (!rport) {
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return -ENOMEM;
	}

	INIT_LIST_HEAD(&rport->luns);
	rport->target_wwpn = target_wwpn;
	rport->target_node_wwpn = target_node_wwpn;
	rport->channel = 0;
	rport->target_id = host->next_target_id++;

	ids.node_name = target_node_wwpn;
	ids.port_name = target_wwpn;
	ids.roles = FC_PORT_ROLE_FCP_TARGET;
	ids.port_id = rport->target_id + 1;

	rport->fc_rport = fc_remote_port_add(host->shost, 0, &ids);
	if (!rport->fc_rport) {
		kfree(rport);
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return -EIO;
	}

	list_add_tail(&rport->node, &host->rports);
	mutex_unlock(&host->lock);
	mutex_unlock(&apollo_hosts_lock);

	pr_info("apollo_fc: create_rport host=%u target=0x%016llx node=0x%016llx id=%u\n",
		host_id,
		(unsigned long long)target_wwpn,
		(unsigned long long)target_node_wwpn,
		rport->target_id);
	return 0;
}

/*
 * apollo_genl_delete_rport() - Remove an rport and all dependent LUN mappings.
 * @skb: Unused request skb.
 * @info: Parsed netlink attributes containing HOST_ID and TARGET_WWPN.
 */
static int apollo_genl_delete_rport(struct sk_buff *skb, struct genl_info *info)
{
	struct apollo_fc_host *host;
	struct apollo_fc_rport *rport;
	struct apollo_fc_lun_map *map;
	struct apollo_fc_lun_map *tmp;
	LIST_HEAD(detached_maps);
	u32 host_id;
	u64 target_wwpn;

	if (!info->attrs[APOLLO_FC_A_HOST_ID] || !info->attrs[APOLLO_FC_A_TARGET_WWPN])
		return -EINVAL;

	host_id = nla_get_u32(info->attrs[APOLLO_FC_A_HOST_ID]);
	target_wwpn = nla_get_u64(info->attrs[APOLLO_FC_A_TARGET_WWPN]);

	mutex_lock(&apollo_hosts_lock);
	host = apollo_find_host_by_id(host_id);
	if (!host) {
		mutex_unlock(&apollo_hosts_lock);
		return -ENOENT;
	}

	mutex_lock(&host->lock);
	rport = apollo_find_rport_by_wwpn(host, target_wwpn);
	if (!rport) {
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return -ENOENT;
	}

	list_del(&rport->node);
	list_for_each_entry_safe(map, tmp, &rport->luns, node) {
		list_del(&map->node);
		list_add_tail(&map->node, &detached_maps);
	}

	if (rport->fc_rport)
		fc_remote_port_delete(rport->fc_rport);

	mutex_unlock(&host->lock);
	mutex_unlock(&apollo_hosts_lock);

	list_for_each_entry_safe(map, tmp, &detached_maps, node) {
		list_del(&map->node);
		if (map->sdev)
			scsi_remove_device(map->sdev);
		map->sdev = NULL;
		apollo_lun_map_put(map);
	}

	pr_info("apollo_fc: delete_rport host=%u target=0x%016llx\n",
		host_id, (unsigned long long)target_wwpn);
	kfree(rport);
	return 0;
}

static int apollo_genl_map_lun(struct sk_buff *skb, struct genl_info *info)
{
	struct apollo_fc_host *host;
	struct apollo_fc_rport *rport;
	struct apollo_fc_lun_map *map;
	u32 host_id, major, minor;
	u64 target_wwpn, lun_id;
	dev_t devt;
	int ret;
	const char *dm_name = NULL;

	if (!info->attrs[APOLLO_FC_A_HOST_ID] ||
	    !info->attrs[APOLLO_FC_A_TARGET_WWPN] ||
	    !info->attrs[APOLLO_FC_A_LUN_ID] ||
	    !info->attrs[APOLLO_FC_A_BACKING_MAJOR] ||
	    !info->attrs[APOLLO_FC_A_BACKING_MINOR])
		return -EINVAL;

	host_id = nla_get_u32(info->attrs[APOLLO_FC_A_HOST_ID]);
	target_wwpn = nla_get_u64(info->attrs[APOLLO_FC_A_TARGET_WWPN]);
	lun_id = nla_get_u64(info->attrs[APOLLO_FC_A_LUN_ID]);
	major = nla_get_u32(info->attrs[APOLLO_FC_A_BACKING_MAJOR]);
	minor = nla_get_u32(info->attrs[APOLLO_FC_A_BACKING_MINOR]);
	if (info->attrs[APOLLO_FC_A_DM_NAME])
		dm_name = nla_data(info->attrs[APOLLO_FC_A_DM_NAME]);

	devt = MKDEV(major, minor);

	mutex_lock(&apollo_hosts_lock);
	host = apollo_find_host_by_id(host_id);
	if (!host) {
		mutex_unlock(&apollo_hosts_lock);
		return -ENOENT;
	}

	mutex_lock(&host->lock);
	rport = apollo_find_rport_by_wwpn(host, target_wwpn);
	if (!rport) {
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return -ENOENT;
	}

	if (apollo_find_lun_map(rport, lun_id)) {
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return 0;
	}

	map = kzalloc(sizeof(*map), GFP_KERNEL);
	if (!map) {
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return -ENOMEM;
	}

	map->lun_id = lun_id;
	map->devt = devt;
	refcount_set(&map->refs, 1);
	if (dm_name)
		strscpy(map->dm_name, dm_name, sizeof(map->dm_name));

	map->bdev_handle = bdev_open_by_dev(devt, BLK_OPEN_READ | BLK_OPEN_WRITE,
					    THIS_MODULE, NULL);
	if (IS_ERR(map->bdev_handle)) {
		ret = PTR_ERR(map->bdev_handle);
		kfree(map);
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return ret;
	}
	map->bdev = map->bdev_handle->bdev;

	list_add_tail(&map->node, &rport->luns);
	mutex_unlock(&host->lock);
	mutex_unlock(&apollo_hosts_lock);

	pr_info("apollo_fc: map_lun host=%u target=0x%016llx lun=%llu backing=%u:%u\n",
		host_id,
		(unsigned long long)target_wwpn,
		(unsigned long long)lun_id,
		major,
		minor);
	return 0;
}

/*
 * apollo_genl_unmap_lun() - Remove one LUN mapping from a target rport.
 * @skb: Unused request skb.
 * @info: Parsed netlink attributes containing host/rport/lun identity.
 *
 * The function detaches map state under lock, then performs potentially
 * sleeping teardown (scsi_remove_device / bdev_release) after unlocking.
 */
static int apollo_genl_unmap_lun(struct sk_buff *skb, struct genl_info *info)
{
	struct apollo_fc_host *host;
	struct apollo_fc_rport *rport;
	struct apollo_fc_lun_map *map;
	u32 host_id;
	u64 target_wwpn;
	u64 lun_id;
	struct scsi_device *sdev = NULL;

	if (!info->attrs[APOLLO_FC_A_HOST_ID] ||
	    !info->attrs[APOLLO_FC_A_TARGET_WWPN] ||
	    !info->attrs[APOLLO_FC_A_LUN_ID])
		return -EINVAL;

	host_id = nla_get_u32(info->attrs[APOLLO_FC_A_HOST_ID]);
	target_wwpn = nla_get_u64(info->attrs[APOLLO_FC_A_TARGET_WWPN]);
	lun_id = nla_get_u64(info->attrs[APOLLO_FC_A_LUN_ID]);

	mutex_lock(&apollo_hosts_lock);
	host = apollo_find_host_by_id(host_id);
	if (!host) {
		mutex_unlock(&apollo_hosts_lock);
		return -ENOENT;
	}

	mutex_lock(&host->lock);
	rport = apollo_find_rport_by_wwpn(host, target_wwpn);
	if (!rport) {
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return -ENOENT;
	}

	map = apollo_find_lun_map(rport, lun_id);
	if (!map) {
		mutex_unlock(&host->lock);
		mutex_unlock(&apollo_hosts_lock);
		return -ENOENT;
	}

	list_del(&map->node);
	sdev = map->sdev;
	map->sdev = NULL;
	mutex_unlock(&host->lock);
	mutex_unlock(&apollo_hosts_lock);

	if (sdev)
		scsi_remove_device(sdev);
	apollo_lun_map_put(map);

	pr_info("apollo_fc: unmap_lun host=%u target=0x%016llx lun=%llu\n",
		host_id,
		(unsigned long long)target_wwpn,
		(unsigned long long)lun_id);
	kfree(map);
	return 0;
}

static int apollo_genl_list_state(struct sk_buff *skb, struct genl_info *info)
{
	u32 host_id = U32_MAX;

	if (info->attrs[APOLLO_FC_A_HOST_ID])
		host_id = nla_get_u32(info->attrs[APOLLO_FC_A_HOST_ID]);

	return apollo_genl_reply_state(info, host_id);
}

static const struct genl_ops apollo_fc_genl_ops[] = {
	{
		.cmd = APOLLO_FC_CMD_CREATE_RPORT,
		.flags = GENL_ADMIN_PERM,
		.policy = apollo_fc_genl_policy,
		.doit = apollo_genl_create_rport,
	},
	{
		.cmd = APOLLO_FC_CMD_DELETE_RPORT,
		.flags = GENL_ADMIN_PERM,
		.policy = apollo_fc_genl_policy,
		.doit = apollo_genl_delete_rport,
	},
	{
		.cmd = APOLLO_FC_CMD_MAP_LUN,
		.flags = GENL_ADMIN_PERM,
		.policy = apollo_fc_genl_policy,
		.doit = apollo_genl_map_lun,
	},
	{
		.cmd = APOLLO_FC_CMD_UNMAP_LUN,
		.flags = GENL_ADMIN_PERM,
		.policy = apollo_fc_genl_policy,
		.doit = apollo_genl_unmap_lun,
	},
	{
		.cmd = APOLLO_FC_CMD_LIST_STATE,
		.flags = GENL_ADMIN_PERM,
		.policy = apollo_fc_genl_policy,
		.doit = apollo_genl_list_state,
	},
};

/* Generic Netlink family registration descriptor for userspace control. */
static struct genl_family apollo_fc_genl_family = {
	.name = APOLLO_FC_GENL_FAMILY_NAME,
	.version = APOLLO_FC_GENL_VERSION,
	.maxattr = APOLLO_FC_A_MAX,
	.module = THIS_MODULE,
	.ops = apollo_fc_genl_ops,
	.n_ops = ARRAY_SIZE(apollo_fc_genl_ops),
};

/*
 * apollo_fc_create_host() - Allocate and register the virtual FC initiator.
 *
 * Returns 0 on success or a negative errno on allocation/registration failure.
 */
static int apollo_fc_create_host(void)
{
	struct Scsi_Host *shost;
	struct apollo_fc_host *host;
	int ret;

	host = kzalloc(sizeof(*host), GFP_KERNEL);
	if (!host)
		return -ENOMEM;

	INIT_LIST_HEAD(&host->rports);
	mutex_init(&host->lock);
	host->next_target_id = 0;

	shost = scsi_host_alloc(&apollo_sht, sizeof(struct apollo_fc_host *));
	if (!shost) {
		kfree(host);
		return -ENOMEM;
	}

	*(struct apollo_fc_host **)shost_priv(shost) = host;
	shost->transportt = apollo_fc_transport;
	shost->max_channel = 0;
	shost->max_id = 4096;
	shost->max_lun = 16384;

	ret = scsi_add_host(shost, NULL);
	if (ret) {
		scsi_host_put(shost);
		kfree(host);
		return ret;
	}

	fc_host_port_name(shost) = initiator_wwpn;
	fc_host_node_name(shost) = initiator_node_wwpn;
	fc_host_port_type(shost) = FC_PORTTYPE_NPORT;
	fc_host_port_state(shost) = FC_PORTSTATE_ONLINE;
	fc_host_speed(shost) = FC_PORTSPEED_16GBIT;
	fc_host_supported_classes(shost) = FC_COS_CLASS3;

	host->shost = shost;
	host->host_id = shost->host_no;

	mutex_lock(&apollo_hosts_lock);
	list_add_tail(&host->node, &apollo_hosts);
	mutex_unlock(&apollo_hosts_lock);

	pr_info("apollo_fc: host created host=%u initiator=0x%016llx node=0x%016llx\n",
		host->host_id,
		(unsigned long long)initiator_wwpn,
		(unsigned long long)initiator_node_wwpn);
	return 0;
}

static void apollo_fc_destroy_hosts(void)
{
	struct apollo_fc_host *host;
	struct apollo_fc_host *tmp;
	struct apollo_fc_rport *rport;
	struct apollo_fc_rport *rport_tmp;
	struct apollo_fc_lun_map *map;
	struct apollo_fc_lun_map *map_tmp;
	LIST_HEAD(detached_maps);

	mutex_lock(&apollo_hosts_lock);
	list_for_each_entry_safe(host, tmp, &apollo_hosts, node) {
		list_del(&host->node);
		mutex_lock(&host->lock);
		list_for_each_entry_safe(rport, rport_tmp, &host->rports, node) {
			list_del(&rport->node);
			list_for_each_entry_safe(map, map_tmp, &rport->luns, node) {
				list_del(&map->node);
				list_add_tail(&map->node, &detached_maps);
			}
			if (rport->fc_rport)
				fc_remote_port_delete(rport->fc_rport);
			kfree(rport);
		}
		mutex_unlock(&host->lock);

		list_for_each_entry_safe(map, map_tmp, &detached_maps, node) {
			list_del(&map->node);
			if (map->sdev)
				scsi_remove_device(map->sdev);
			map->sdev = NULL;
			apollo_lun_map_put(map);
		}

		scsi_remove_host(host->shost);
		scsi_host_put(host->shost);
		kfree(host);
	}
	mutex_unlock(&apollo_hosts_lock);
}

static int __init apollo_fc_init(void)
{
	int ret;

	apollo_fc_transport = fc_attach_transport(&apollo_fc_function_template);
	if (!apollo_fc_transport)
		return -ENOMEM;

	ret = genl_register_family(&apollo_fc_genl_family);
	if (ret) {
		fc_release_transport(apollo_fc_transport);
		pr_err("apollo_fc: failed to register netlink family: %d\n", ret);
		return ret;
	}

	ret = apollo_fc_create_host();
	if (ret) {
		genl_unregister_family(&apollo_fc_genl_family);
		fc_release_transport(apollo_fc_transport);
		pr_err("apollo_fc: failed to create host: %d\n", ret);
		return ret;
	}

	pr_info("apollo_fc: loaded family=%s version=%d\n",
		APOLLO_FC_GENL_FAMILY_NAME, APOLLO_FC_GENL_VERSION);
	return 0;
}

static void __exit apollo_fc_exit(void)
{
	apollo_fc_destroy_hosts();
	genl_unregister_family(&apollo_fc_genl_family);
	if (apollo_fc_transport)
		fc_release_transport(apollo_fc_transport);
	pr_info("apollo_fc: unloaded\n");
}

module_init(apollo_fc_init);
module_exit(apollo_fc_exit);

MODULE_DESCRIPTION("Apollo Fake Fibre Channel transport emulator");
MODULE_AUTHOR("Lunacy Systems");
MODULE_LICENSE("GPL");