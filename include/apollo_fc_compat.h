/* SPDX-License-Identifier: GPL-2.0-only */
#ifndef APOLLO_FC_COMPAT_H
#define APOLLO_FC_COMPAT_H

#include <linux/version.h>
#include <linux/types.h>
#include <linux/kernel.h>

#define APOLLO_FC_GENL_FAMILY_NAME "apollo_fc"
#define APOLLO_FC_GENL_VERSION 1

#define APOLLO_FC_DM_TARGET_NAME "apollo_fc"

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 8, 0)
#define APOLLO_FC_HAS_PRE_68_API 1
#else
#define APOLLO_FC_HAS_PRE_68_API 0
#endif

static inline u64 apollo_fc_get_unaligned_be64(const u8 *buf)
{
	return ((u64)buf[0] << 56) | ((u64)buf[1] << 48) |
		((u64)buf[2] << 40) | ((u64)buf[3] << 32) |
		((u64)buf[4] << 24) | ((u64)buf[5] << 16) |
		((u64)buf[6] << 8) | (u64)buf[7];
}

static inline u32 apollo_fc_get_unaligned_be32(const u8 *buf)
{
	return ((u32)buf[0] << 24) | ((u32)buf[1] << 16) |
		((u32)buf[2] << 8) | (u32)buf[3];
}

static inline void apollo_fc_put_unaligned_be64(u64 val, u8 *buf)
{
	buf[0] = (val >> 56) & 0xff;
	buf[1] = (val >> 48) & 0xff;
	buf[2] = (val >> 40) & 0xff;
	buf[3] = (val >> 32) & 0xff;
	buf[4] = (val >> 24) & 0xff;
	buf[5] = (val >> 16) & 0xff;
	buf[6] = (val >> 8) & 0xff;
	buf[7] = val & 0xff;
}

static inline void apollo_fc_put_unaligned_be32(u32 val, u8 *buf)
{
	buf[0] = (val >> 24) & 0xff;
	buf[1] = (val >> 16) & 0xff;
	buf[2] = (val >> 8) & 0xff;
	buf[3] = val & 0xff;
}

#endif