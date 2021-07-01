all    :; dapp build
clean  :; dapp clean
test   :; source .env && dapp test --rpc ${RPC_URL}
test-v   :; source .env && dapp test --verbose --rpc ${RPC_URL}
deploy :; dapp create Drai
