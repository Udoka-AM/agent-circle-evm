.PHONY: install build test journey gas coverage fmt lint anvil deploy-local clean

install:
	forge install

build:
	forge build

test:
	forge test

# The whole product as a printed walkthrough. Start here.
journey:
	forge test --match-contract Journey -vv

gas:
	forge snapshot --check || forge snapshot

coverage:
	forge coverage --no-match-coverage "(test|script)"

fmt:
	forge fmt

lint:
	forge fmt --check && forge build

anvil:
	anvil --port 8546

# Requires `make anvil` in another terminal.
deploy-local:
	forge script script/DeployLocal.s.sol:DeployLocal \
		--rpc-url http://127.0.0.1:8546 --broadcast

deploy-amoy:
	forge script script/Deploy.s.sol:Deploy \
		--rpc-url amoy --broadcast --verify --slow

clean:
	forge clean
