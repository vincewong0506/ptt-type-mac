// Shim that replaces ESP-IDF's `common/bt_target.h` for the vendored OI SBC
// decoder sources. The decoder srce/*.c files include this header before any
// SBC code; we just need TRUE/FALSE and SBC_DEC_INCLUDED to be defined so the
// `#if (defined(SBC_DEC_INCLUDED) && SBC_DEC_INCLUDED == TRUE)` guards open.

#ifndef LTAID_SBC_BT_TARGET_SHIM_H
#define LTAID_SBC_BT_TARGET_SHIM_H

#ifndef FALSE
#define FALSE 0
#endif

#ifndef TRUE
#define TRUE (!FALSE)
#endif

#ifndef SBC_DEC_INCLUDED
#define SBC_DEC_INCLUDED TRUE
#endif

#endif
