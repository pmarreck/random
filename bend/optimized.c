Term random_bend_optimized_run(Env e, Term *f, IoWork *w) {
	(void)e; (void)f; (void)w;
#if defined(__OPTIMIZE__)
	return (Term)1;
#else
	return (Term)0;
#endif
}
static void __attribute__((constructor)) random_bend_optimized_use(void) {
	io_eff(CID(optimized_native), random_bend_optimized_run);
}
