all    :; dapp build
clean  :; dapp clean
test   :; dapp test --rpc ${ETH_RPC_URL} --rpc-block 13633752
test-v :; DAPP_TEST_VERBOSITY=2 dapp test --rpc ${ETH_RPC_URL} --rpc-block 13633752
deploy :; dapp create Drai
