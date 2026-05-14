async function main() {
  console.log("Starting deploy...");
  const Contract = await ethers.getContractFactory("PredictionMarket");
  console.log("Deploying...");
  const contract = await Contract.deploy();
  console.log("Waiting for deployment...");
  await contract.waitForDeployment();
  const address = await contract.getAddress();
  console.log("Deployed to:", address);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
