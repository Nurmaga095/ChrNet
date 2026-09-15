#ifndef RUNNER_SERVICE_CHECK_H_
#define RUNNER_SERVICE_CHECK_H_

// "chrnet.exe --service-check [--start-test]" reaches the installed ChrNet
// service exactly the way the app does and prints what it finds, for support
// and diagnostics. --start-test also starts and stops a throwaway proxy-only
// core on spare ports, which ends any connection the service currently holds.
int RunServiceCheck(bool start_test);

#endif  // RUNNER_SERVICE_CHECK_H_
