import {
  Account,
  AccountAddress,
  Aptos,
  AptosConfig,
  Ed25519PrivateKey,
  InputGenerateTransactionPayloadData,
  Network,
  UserTransactionResponse,
} from "@aptos-labs/ts-sdk";
import dotenv from "dotenv";
dotenv.config();

const config = new AptosConfig({
  network: Network.CUSTOM,
  fullnode: process.env.FULLNODE,
  faucet: process.env.FAUCET,
  indexer: process.env.INDEXER,
});

const aptos = new Aptos(config);

const supplyTokenSymbol = "IDO";
const purchaseTokenSymbol = "USDC";
const deployer = getAccount(process.env.PRIVATE_KEY!);
const deployerAddress = deployer.accountAddress.toString();
const adminSigner = getAccount(process.env.ADMIN_PRIVATE_KEY!);
const adminAddress = adminSigner.accountAddress.toString();
const user1Signer = getAccount(process.env.USER1_PRIVATE_KEY!);
const user1Address = user1Signer.accountAddress.toString();
const user2Signer = getAccount(process.env.USER2_PRIVATE_KEY!);
const user2Address = user2Signer.accountAddress.toString();
const user3Signer = getAccount(process.env.USER3_PRIVATE_KEY!);
const user3Address = user3Signer.accountAddress.toString();
const moduleAddress = process.env.MOVERNANCE_PAD_ADDRESS!;

function assert(condition: boolean, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

async function getCoinBalance(
  coinType: string,
  accountAddress: string,
): Promise<bigint> {
  // console.dir({ coinType, accountAddress }, { depth: null });
  try {
    const res = await aptos.view({
      payload: {
        function: `0x1::coin::balance`,
        functionArguments: [accountAddress],
        typeArguments: [coinType],
      },
    });
    //   console.dir({ res }, { depth: null });
    return BigInt(parseInt(res[0] as string));
  } catch (e) {
    console.log(`error: ${e}`);
    return BigInt(0);
  }
}

function getAccount(privateKeyHex: string): Account {
  const privateKeyBytes = Buffer.from(privateKeyHex.slice(2), "hex");
  const privateKey = new Ed25519PrivateKey(privateKeyBytes);
  return Account.fromPrivateKey({ privateKey });
}

async function fundAddresses(
  from: Account,
  addresses: string[],
  amount: bigint,
) {
  for (const addr of addresses) {
    const sendMoveTxn = await aptos.transferCoinTransaction({
      sender: from.accountAddress.toString(),
      recipient: addr,
      amount,
    });
    const fundTxn = await aptos.signAndSubmitTransaction({
      transaction: sendMoveTxn,
      signer: from,
    });
    console.log(`transferred ${amount} to ${addr}, txn hash: ${fundTxn.hash}`);
    await aptos.waitForTransaction({ transactionHash: fundTxn.hash });
  }
}

async function checkAccounts() {
  const deployerBalance = await getCoinBalance(
    "0x1::aptos_coin::AptosCoin",
    deployer.accountAddress.toString(),
  );
  console.dir({ deployerAddress, deployerBalance }, { depth: null });

  console.dir({ adminAddress, user1Address, user2Address, user3Address }, {
    depth: null,
  });

  // await fundAddresses(deployer, [adminAddress, user1Address, user2Address, user3Address], 100000000n);
  const adminBalance = await getCoinBalance(
    "0x1::aptos_coin::AptosCoin",
    adminAddress,
  );
  const user1Balance = await getCoinBalance(
    "0x1::aptos_coin::AptosCoin",
    user1Address,
  );
  const user2Balance = await getCoinBalance(
    "0x1::aptos_coin::AptosCoin",
    user2Address,
  );
  const user3Balance = await getCoinBalance(
    "0x1::aptos_coin::AptosCoin",
    user3Address,
  );
  console.dir({ adminBalance, user1Balance, user2Balance, user3Balance }, {
    depth: null,
  });
}

async function createTokens() {
  // create fa and mint to users
  const createSupplyTokenTxn = await aptos.transaction.build.simple({
    sender: adminSigner.accountAddress,
    data: {
      function: `${moduleAddress}::TestFA::create_fa`,
      functionArguments: [
        supplyTokenSymbol,
        supplyTokenSymbol,
        "6",
      ],
    },
  });
  const createSupplyTokenTxResponse = await aptos.signAndSubmitTransaction({
    transaction: createSupplyTokenTxn,
    signer: adminSigner,
  });
  console.log(
    `create supply token txn hash: ${createSupplyTokenTxResponse.hash}`,
  );
  await aptos.waitForTransaction({
    transactionHash: createSupplyTokenTxResponse.hash,
  });
  const createPurchaseTokenTxn = await aptos.transaction.build.simple({
    sender: adminSigner.accountAddress,
    data: {
      function: `${moduleAddress}::TestFA::create_fa`,
      functionArguments: [
        purchaseTokenSymbol,
        purchaseTokenSymbol,
        "6",
      ],
    },
  });
  const createPurchaseTokenTxResponse = await aptos.signAndSubmitTransaction({
    transaction: createPurchaseTokenTxn,
    signer: adminSigner,
  });
  console.log(
    `create purchase token txn hash: ${createPurchaseTokenTxResponse.hash}`,
  );
  await aptos.waitForTransaction({
    transactionHash: createPurchaseTokenTxResponse.hash,
  });
}

async function mintToken(signer: Account, symbol: string, amount: bigint) {
  const mintTokenTxn = await aptos.transaction.build.simple({
    sender: signer.accountAddress,
    data: {
      function: `${moduleAddress}::TestFA::mint`,
      functionArguments: [symbol, amount],
    },
  });
  const mintTokenTxResponse = await aptos.signAndSubmitTransaction({
    transaction: mintTokenTxn,
    signer: signer,
  });
  console.log(
    `mint token txn hash: ${mintTokenTxResponse.hash}`,
  );
  await aptos.waitForTransaction({
    transactionHash: mintTokenTxResponse.hash,
  });
}

async function mintTokens() {
  await Promise.all([
    mintToken(adminSigner, supplyTokenSymbol, 100_000_000_000_000n),
    mintToken(user1Signer, purchaseTokenSymbol, 100_000_000_000_000n),
    mintToken(user2Signer, purchaseTokenSymbol, 100_000_000_000_000n),
    mintToken(user3Signer, purchaseTokenSymbol, 100_000_000_000_000n),
  ]);
}

async function getMetadataAddress(symbol: string) {
  const metadataAddressResponse = await aptos.view({
    payload: {
      function: `${moduleAddress}::TestFA::get_metadata_by_symbol`,
      functionArguments: [symbol],
    },
  });
  return metadataAddressResponse[0]!.toString();
}

async function getMetadataAddresses() {
  const supplyMetadataAddress = await getMetadataAddress(supplyTokenSymbol);
  const purchaseMetadataAddress = await getMetadataAddress(purchaseTokenSymbol);
  return { supplyMetadataAddress, purchaseMetadataAddress };
}

async function checkFungibleAssetBalance(
  address: string,
  metadataAddress: string,
) {
  const balance = await aptos.view({
    payload: {
      function: `0x1::primary_fungible_store::balance`,
      functionArguments: [
        address,
        metadataAddress,
      ],
      typeArguments: ["0x1::fungible_asset::Metadata"],
    },
  });
  // console.dir({ balance }, { depth: null });
  return BigInt(balance[0]!.toString());
}

async function checkFungibleAssetBalances() {
  const { supplyMetadataAddress, purchaseMetadataAddress } =
    await getMetadataAddresses();
  const adminSupplyBalance = await checkFungibleAssetBalance(
    adminAddress,
    supplyMetadataAddress,
  );
  const user1PurchaseBalance = await checkFungibleAssetBalance(
    user1Address,
    purchaseMetadataAddress,
  );
  const user2PurchaseBalance = await checkFungibleAssetBalance(
    user2Address,
    purchaseMetadataAddress,
  );
  const user3PurchaseBalance = await checkFungibleAssetBalance(
    user3Address,
    purchaseMetadataAddress,
  );
  console.dir({
    adminSupplyBalance,
    user1PurchaseBalance,
    user2PurchaseBalance,
    user3PurchaseBalance,
  }, { depth: null });
}

async function interact() {
  const { supplyMetadataAddress, purchaseMetadataAddress } =
    await getMetadataAddresses();
  // create pool
  const nowInSeconds = Math.floor(Date.now() / 1000);
  const idoStartTime = nowInSeconds + 30;
  const idoEndTime = idoStartTime + 30;
  const claimStartTime = idoEndTime;
  const hardCap = 1_000_000_000_000n;  // 1M
  const idoSupply = 5_000_000_000_000n; // 5M
  const minimumPurchaseAmount = 10_000_000n; // 10 USDC
  const createPoolTxn = await aptos.transaction.build.simple({
    sender: adminSigner.accountAddress,
    data: {
      function: `${moduleAddress}::LaunchpadV2::create_pool`,
      functionArguments: [
        supplyMetadataAddress,
        purchaseMetadataAddress,
        adminAddress,
        idoStartTime,
        idoEndTime,
        claimStartTime,
        hardCap,
        idoSupply,
        minimumPurchaseAmount,
      ],
    },
  });
  const createPoolTxResponse = await aptos.signAndSubmitTransaction({
    transaction: createPoolTxn,
    signer: adminSigner,
  });
  console.log(`create pool txn hash: ${createPoolTxResponse.hash}`);
  const createPoolTxReceipt = await aptos.waitForTransaction({
    transactionHash: createPoolTxResponse.hash,
  });
  console.dir({ createPoolTxReceipt }, { depth: null });
  const poolId =
    (createPoolTxReceipt as any).events.find((event: any) =>
      event.type.includes("PoolCreated")
    )!.data.pool;
  console.log(`pool id: ${poolId}`);
  // deposit supply token
  const depositSupplyTokenTxn = await aptos.transaction.build.simple({
    sender: adminAddress,
    data: {
      function: `${moduleAddress}::LaunchpadV2::deposit_supply_token`,
      functionArguments: [
        poolId,
        idoSupply.toString(),
      ],
    },
  });
  const depositSupplyTokenTxResponse = await aptos.signAndSubmitTransaction({
    transaction: depositSupplyTokenTxn,
    signer: adminSigner,
  });
  console.log(
    `deposit supply token txn hash: ${depositSupplyTokenTxResponse.hash}`,
  );
  const depositSupplyTokenTxReceipt = await aptos.waitForTransaction({
    transactionHash: depositSupplyTokenTxResponse.hash,
  });
  console.dir({ depositSupplyTokenTxReceipt }, { depth: null });
  // update whitelist
  const whiteListAmount = 100_000_000n;  // 100 USDC
  const whitelist = [user1Address, user2Address];
  const updateWhitelistTxn = await aptos.transaction.build.simple({
    sender: adminAddress,
    data: {
      function: `${moduleAddress}::LaunchpadV2::update_whitelist`,
      functionArguments: [
        poolId,
        whitelist,
        whiteListAmount,
      ],
    },
  });
  const updateWhitelistTxResponse = await aptos.signAndSubmitTransaction({
    transaction: updateWhitelistTxn,
    signer: adminSigner,
  });
  console.log(`update whitelist txn hash: ${updateWhitelistTxResponse.hash}`);
  const updateWhitelistTxReceipt = await aptos.waitForTransaction({
    transactionHash: updateWhitelistTxResponse.hash,
  });
  console.dir({ updateWhitelistTxReceipt }, { depth: null });
  // set pool ready
  const setPoolReadyTxn = await aptos.transaction.build.simple({
    sender: adminAddress,
    data: {
      function: `${moduleAddress}::LaunchpadV2::set_pool_ready`,
      functionArguments: [
        poolId,
      ],
    },
  });
  const setPoolReadyTxResponse = await aptos.signAndSubmitTransaction({
    transaction: setPoolReadyTxn,
    signer: adminSigner,
  });
  console.log(`set pool ready txn hash: ${setPoolReadyTxResponse.hash}`);
  const setPoolReadyTxReceipt = await aptos.waitForTransaction({
    transactionHash: setPoolReadyTxResponse.hash,
  });
  console.dir({ setPoolReadyTxReceipt }, { depth: null });
  await getPoolsView([poolId]);
  // wait for ido start time
  console.log(`waiting for ido start time: ${idoStartTime}`);
  await waitUntilSpecificTimestamp(idoStartTime);
  // users purchase tokens
  const user1Amount = 50_000_000n;
  const user2Amount = 200_000_000n;
  const user3Amount = 6_000_000_000_000n;
  await Promise.all([
    purchase(user1Signer, poolId, user1Amount),
    purchase(user2Signer, poolId, user2Amount),
    purchase(user3Signer, poolId, user3Amount),
  ]);
  await getClaimableAmount(user1Address, poolId);
  await getPoolsView([poolId]);
  // set current time to claim start time
  console.log(`waiting for claim start time: ${claimStartTime}`);
  await waitUntilSpecificTimestamp(claimStartTime);
  // users claim tokens
  await getClaimableAmount(user1Address, poolId);
  await getClaimableAmount(user2Address, poolId);
  await getClaimableAmount(user3Address, poolId);
  await Promise.all([
    claim(user1Signer, poolId),
    claim(user2Signer, poolId),
    claim(user3Signer, poolId),
  ]);
  // admin withdraws purchase tokens
  const withdrawTxn = await aptos.transaction.build.simple({
    sender: adminAddress,
    data: {
      function: `${moduleAddress}::LaunchpadV2::withdraw`,
      functionArguments: [
        poolId,
      ],
    },
  });
  const withdrawTxResponse = await aptos.signAndSubmitTransaction({
    transaction: withdrawTxn,
    signer: adminSigner,
  });
  console.log(`withdraw txn hash: ${withdrawTxResponse.hash}`);
  const withdrawTxReceipt = await aptos.waitForTransaction({
    transactionHash: withdrawTxResponse.hash,
  });
  console.dir({ withdrawTxReceipt }, { depth: null });
  await getPoolsView([poolId]);
}

async function getClaimableAmount(userAddr: string, poolId: string) {
  const claimableAmount = await aptos.view({
    payload: {
      function: `${moduleAddress}::LaunchpadV2::get_claimable_amount`,
      functionArguments: [
        userAddr,
        poolId,
      ],
    },
  });
  console.dir({ claimableAmount }, { depth: null });
}

async function claim(signer: Account, poolId: string) {
  const claimTxn = await aptos.transaction.build.simple({
    sender: signer.accountAddress,
    data: {
      function: `${moduleAddress}::LaunchpadV2::claim`,
      functionArguments: [
        signer.accountAddress,
        poolId,
      ],
    },
  });
  const claimTxResponse = await aptos.signAndSubmitTransaction({
    transaction: claimTxn,
    signer: signer,
  });
  console.log(`claim txn hash: ${claimTxResponse.hash}`);
  const claimTxReceipt = await aptos.waitForTransaction({
    transactionHash: claimTxResponse.hash,
  });
  console.dir({ claimTxReceipt }, { depth: null });
}

async function purchase(signer: Account, poolId: string, amount: bigint) {
  const purchaseTxn = await aptos.transaction.build.simple({
    sender: signer.accountAddress,
    data: {
      function: `${moduleAddress}::LaunchpadV2::purchase`,
      functionArguments: [
        poolId,
        amount,
      ],
    },
  });
  const purchaseTxResponse = await aptos.signAndSubmitTransaction({
    transaction: purchaseTxn,
    signer: signer,
  });
  console.log(`purchase txn hash: ${purchaseTxResponse.hash}`);
  const purchaseTxReceipt = await aptos.waitForTransaction({
    transactionHash: purchaseTxResponse.hash,
  });
  console.dir({ purchaseTxReceipt }, { depth: null });
}

async function getPoolsView(pools: string[]) {
  const poolsView = await aptos.view({
    payload: {
      function: `${moduleAddress}::LaunchpadV2::get_pools_view`,
      functionArguments: [
        pools,
      ],
    },
  });
  console.dir({ poolsView }, { depth: null });
}

async function waitUntilSpecificTimestamp(
  targetTimestamp: number,
): Promise<void> {
  while (true) {
    const currentTimestamp = Math.floor(Date.now() / 1000);

    console.log(
      `current timestamp: ${currentTimestamp}, target timestamp: ${targetTimestamp}, left ${
        targetTimestamp - currentTimestamp
      } seconds`,
    );
    if (currentTimestamp >= targetTimestamp) {
      return;
    }

    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
}

async function main() {
  console.log(`--------- movernance pad demo --------`);

  // check chain status
  // const ledgerInfo = await aptos.getLedgerInfo();
  // console.dir({ ledgerInfo }, { depth: null });

  await checkAccounts();
  await createTokens();
  await mintTokens();
  await checkFungibleAssetBalances();
  await interact();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
