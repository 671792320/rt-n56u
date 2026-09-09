/*
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation; either version 2 of
 * the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston,
 * MA 02111-1307 USA
 */

#include <ralink_boards.h>
#include "nvram_linux.h"
#include "netutils.h"
#include "q7_defaults.h"

#define STR1(x) #x
#define STR(x) STR1(x)

struct nvram_pair router_defaults[] = {
	/* Restore defaults */
	{ "restore_defaults", "0" },		/* Set to 0 to not restore defaults on boot */
	{ "nvram_manual", "0" },		/* Manual commit mode: 1: manual, 0: auto */

#if defined (USE_NAND_FLASH)
	{ "mtd_rwfs_mount", "0" },		/* Allow mount MTD RWFS partition on boot */
#endif

	/* Miscellaneous parameters */