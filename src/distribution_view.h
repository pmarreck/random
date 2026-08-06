#ifndef RANDOMZ_DISTRIBUTION_VIEW_H
#define RANDOMZ_DISTRIBUTION_VIEW_H

#include "randomz.h"

typedef enum distribution_view_output {
	DISTRIBUTION_VIEW_UTF8,
	DISTRIBUTION_VIEW_KITTY,
	DISTRIBUTION_VIEW_SIXEL
} distribution_view_output;

/* Writes only the graphical payload (plus the rows reserved by terminal image
 * protocols). Returns a randomz_status, or -1 for allocation/output failure. */
int distribution_view_render(randomz_distribution distribution,
	randomz_fixed first, randomz_fixed second, distribution_view_output output);

#endif
