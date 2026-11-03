int ol_harness_init(void);
int ol_harness_start(const char *ip, int port, const char *tx, const char *rx, unsigned ssrc, int txPt, int rxPt);
void ol_harness_stats(unsigned *rx, unsigned *lost, unsigned *tx, int *level);
void ol_harness_stop(void);
