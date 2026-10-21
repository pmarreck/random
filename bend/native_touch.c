/* A reachability sink, not a numerical operation or an alternative RNG. */
Term random_bend_native_touch_run(Env e, Term *fields, IoWork *work) {
	(void)work;
	term_drop(e, fields[0]);
	return term_pak(CID_UNIT, 0);
}
static void __attribute__((constructor)) random_bend_native_touch_use(void) {
	io_eff(CID(touch), random_bend_native_touch_run);
}
