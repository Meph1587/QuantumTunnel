import { ethers } from 'hardhat';
import { BigNumber, Contract, Signer } from 'ethers';
import * as accounts from '../helpers/accounts';
import { expect } from 'chai';
import { QuantumTunnelSender, QuantumTunnelReceiver, ConnextHandlerMock, ExecutorMock, BridgedERC721} from '../typechain';
import * as chain from '../helpers/chain';
import * as deploy from '../helpers/deploy';

describe('QuantumTunnelReceiver', function () {

    let user: Signer;
    let user2: Signer;
    let userAddress: string;

    let executor: ExecutorMock;
    let tunnel: QuantumTunnelReceiver;
    let handler: ConnextHandlerMock;
    let bridgedERC721: BridgedERC721;
    let snapshotId: any;
    
    let originToken = "0x0000000000000000000000000000000000000001"
    let sender = "0x0000000000000000000000000000000000000002"
    let unusedAsset ="0x0000000000000000000000000000000000000003"
    let originDomain = 1
    let destinationDomain = 2
    let relayerFee = 10000;
    


    before(async function () {
        executor = (await deploy.deployContract('ExecutorMock')) as unknown as ExecutorMock;
        handler = (await deploy.deployContract('ConnextHandlerMock', [executor.address])) as unknown as ConnextHandlerMock;
        tunnel = (await deploy.deployContract('QuantumTunnelReceiver', [handler.address, destinationDomain, originDomain, unusedAsset])) as unknown as QuantumTunnelReceiver;
        bridgedERC721 = (await deploy.deployContract('BridgedERC721', ["", chain.zeroAddress, 0]))as unknown as BridgedERC721;

        user = (await ethers.getSigners())[0]
        userAddress = await user.getAddress()
        user2 = (await ethers.getSigners())[1]

        await tunnel.mapContract(originToken, bridgedERC721.address);
        await tunnel.setOriginContract(sender);
        await executor.setOrigins(sender, originDomain)
        await bridgedERC721.setMinter(tunnel.address)
        
        await chain.setTime(await chain.getCurrentUnix());

    });

    beforeEach(async function () {
        snapshotId = await ethers.provider.send('evm_snapshot', []);
    });

    afterEach(async function () {
        const ts = await chain.getLatestBlockTimestamp();

        await ethers.provider.send('evm_revert', [snapshotId]);

        await chain.moveAtTimestamp(ts + 5);
    });

    describe('General tests', function () {
        it('should be deployed', async function () {
            expect(tunnel.address).to.not.equal(0);
        });
    });
    

    describe('Deposit', function () {
        it('let executor trigger Mint', async function () {
            
            let iface = new ethers.utils.Interface([
                "function executeXCallMint(address,address,uint256,uint256) "
            ]);
            let callData = iface.encodeFunctionData("executeXCallMint", [
                    await user.getAddress(),
                    originToken,
                    93,
                    await chain.getLatestBlockTimestamp(),
                ]);
            
                await executor.execute(tunnel.address, callData, {gasLimit:5000000});

                expect(await bridgedERC721.ownerOf(93)).to.eq(await user.getAddress());
            
        });

        it('reverts if non-executer triggers Mint', async function () {
            
            let iface = new ethers.utils.Interface([
                "function executeXCallMint(address,address,uint256,uint256) "
            ]);
            let callData = iface.encodeFunctionData("executeXCallMint", [
                    await user.getAddress(),
                    originToken,
                    93,
                    await chain.getLatestBlockTimestamp(),
                ]);
            
            let fakeExecutor = (await deploy.deployContract('ExecutorMock')) as unknown as ExecutorMock;
            await expect(fakeExecutor.execute(tunnel.address, callData, {gasLimit:5000000})).to.be.revertedWith("QuantumTunnel: sender invalid")
            
        });
    });
    describe('Withdraw', function () {
        beforeEach( async function() {
            let iface = new ethers.utils.Interface([
                "function executeXCallMint(address,address,uint256,uint256) "
            ]);
            let callData = iface.encodeFunctionData("executeXCallMint", [
                    await user.getAddress(),
                    originToken,
                    93,
                    await chain.getLatestBlockTimestamp() + 10000,
                ]);
            
            await executor.execute(tunnel.address, callData, {gasLimit:5000000});
        })


        it('does not let user withdraw before lock', async function () {
            await expect(
                tunnel.withdraw(originToken, 93, 0, relayerFee, {value:relayerFee} )
            ).to.be.revertedWith("still locked");
        });

        it('let executor triggers withdraw', async function () {

            await chain.moveAtTimestamp(await chain.getLatestBlockTimestamp() + 10000 + 100)
           
            await tunnel.withdraw(originToken, 93, 0, relayerFee, {value:relayerFee} );
            
            //token was burned
            expect(await bridgedERC721.totalSupply()).to.eq(0);

            //payment to relayer
            expect(await ethers.provider.getBalance(handler.address)).to.eq(relayerFee)

            let args = await handler.args();
            expect(args.params.to).to.eq(sender);
            expect(args.params.destinationDomain).to.eq(originDomain);
            
            let iface = new ethers.utils.Interface([
                "function executeXCallWithdraw(address,uint256) "
            ]);
            let callData = iface.encodeFunctionData("executeXCallWithdraw", [
                    originToken,
                    93,
                ]);
            expect(args.params.callData).to.eq(callData);
        
        });

        it('does not let user withdraw if origin is 0', async function () {
            await chain.moveAtTimestamp(await chain.getLatestBlockTimestamp() + 10000 + 100)
            await tunnel.setOriginContract(chain.zeroAddress);
            await expect(
                tunnel.withdraw(originToken, 93, 0, relayerFee, {value:relayerFee} )
            ).to.be.revertedWith("QTReceiver: origin contract not set");
        });

        it('does not let user withdraw without paying fee', async function () {
            await expect(
                tunnel.withdraw(originToken, 93, 0, relayerFee, {value:0} )
            ).to.be.revertedWith("QTReceiver: value to low to cover relayer and callback fee");
        });

        it('does not let user withdraw a non-owned token', async function () {
            await bridgedERC721.setMinter(userAddress);
            await bridgedERC721.mint(await user2.getAddress(), 90);
            await expect(
                tunnel.withdraw(originToken, 90, 0, relayerFee, {value:relayerFee} )
            ).to.be.revertedWith("QTReceiver: not called by the owner of the token");
        });


    });

    
});