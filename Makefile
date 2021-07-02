all    :; dapp build
clean  :; dapp clean
test   :; dapp test --rpc ${ETH_RPC_URL}
test-v   :; dapp test --verbose --rpc ${ETH_RPC_URL}
deploy :; dapp create Drai
