// SPDX-License-Identifier: GPL-2.0-only
/*
 * M1892 product wrapper for the physically accepted R259 DW7914 driver.
 *
 * Keep the safety-reviewed implementation in one source file while selecting
 * its direct-GPIO power ownership and standard Linux force-feedback ABI for
 * the daily kernel.
 */
#define DW7914_DIRECT_GPIO_POWER
#define DW7914_STANDARD_FF
#include "m1892-dw7914-safe-pulse.c"
