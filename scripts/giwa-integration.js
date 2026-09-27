export const GIWA_PVP_CONTRACT_ADDRESS = "0xB464f766028C1d4Face359592a2127272C2C7750";
/**
 * GIWA Sepolia Testnet Configuration & Frontend Integration
 * Supports viem / wagmi / ethers / window.ethereum
 */

// 1. Chain Specification
export const giwaSepolia = {
  id: 91342,
  name: 'GIWA Sepolia',
  network: 'giwa-sepolia',
  nativeCurrency: {
    name: 'Ether',
    symbol: 'ETH',
    decimals: 18,
  },
  rpcUrls: {
    default: {
      http: ['https://sepolia-rpc.giwa.io'],
    },
    flashblocks: {
      http: ['https://sepolia-rpc-flashblocks.giwa.io'],
    },
    public: {
      http: ['https://sepolia-rpc.giwa.io'],
    },
  },
  blockExplorers: {
    default: {
      name: 'GIWA Explorer',
      url: 'https://sepolia-explorer.giwa.io',
    },
  },
  testnet: true,
};

// 2. Network Switcher Helper for Browser Wallets (MetaMask, Rabby, Coinbase Wallet)
export async function switchToGiwaNetwork() {
  if (!window.ethereum) throw new Error('No EVM wallet detected');

  const chainIdHex = '0x' + (91342).toString(16);

  try {
    await window.ethereum.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: chainIdHex }],
    });
  } catch (switchError) {
    // 4902 means chain has not been added to wallet
    if (switchError.code === 4902) {
      await window.ethereum.request({
        method: 'wallet_addEthereumChain',
        params: [
          {
            chainId: chainIdHex,
            chainName: 'GIWA Sepolia Testnet',
            nativeCurrency: {
              name: 'Ether',
              symbol: 'ETH',
              decimals: 18,
            },
            rpcUrls: ['https://sepolia-rpc.giwa.io'],
            blockExplorerUrls: ['https://sepolia-explorer.giwa.io'],
          },
        ],
      });
    } else {
      throw switchError;
    }
  }
}

// 3. Contract ABI for PvPArenaGIWA
export const PVP_ARENA_GIWA_ABI = [
  {
    inputs: [
      { internalType: 'address', name: '_resolver', type: 'address' },
      { internalType: 'address', name: '_treasury', type: 'address' },
    ],
    stateMutability: 'nonpayable',
    type: 'constructor',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'duelId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'creator', type: 'address' },
      { indexed: false, internalType: 'address', name: 'token', type: 'address' },
      { indexed: false, internalType: 'uint256', name: 'entryStake', type: 'uint256' },
      { indexed: false, internalType: 'string', name: 'marketSymbol', type: 'string' },
    ],
    name: 'DuelCreated',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'duelId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'challenger', type: 'address' },
    ],
    name: 'DuelJoined',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'duelId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'winner', type: 'address' },
      { indexed: false, internalType: 'uint256', name: 'winnerPayout', type: 'uint256' },
      { indexed: false, internalType: 'uint256', name: 'loserCashback', type: 'uint256' },
    ],
    name: 'DuelResolved',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'duelId', type: 'uint256' },
      { indexed: true, internalType: 'address', name: 'creator', type: 'address' },
    ],
    name: 'DuelCancelled',
    type: 'event',
  },
  {
    anonymous: false,
    inputs: [
      { indexed: true, internalType: 'uint256', name: 'duelId', type: 'uint256' },
    ],
    name: 'DuelRefunded',
    type: 'event',
  },
  {
    inputs: [
      { internalType: 'address', name: 'token', type: 'address' },
      { internalType: 'uint256', name: 'entryStake', type: 'uint256' },
      { internalType: 'uint256', name: 'targetPrice', type: 'uint256' },
      { internalType: 'bool', name: 'isCreatorLong', type: 'bool' },
      { internalType: 'uint256', name: 'entryDeadline', type: 'uint256' },
      { internalType: 'uint256', name: 'settlementTime', type: 'uint256' },
      { internalType: 'string', name: 'marketSymbol', type: 'string' },
    ],
    name: 'createDuel',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: 'duelId', type: 'uint256' }],
    name: 'joinDuel',
    outputs: [],
    stateMutability: 'payable',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: 'duelId', type: 'uint256' }],
    name: 'cancelDuel',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [
      { internalType: 'uint256', name: 'duelId', type: 'uint256' },
      { internalType: 'address', name: 'winner', type: 'address' },
    ],
    name: 'resolveDuel',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: 'duelId', type: 'uint256' }],
    name: 'emergencyRefund',
    outputs: [],
    stateMutability: 'nonpayable',
    type: 'function',
  },
  {
    inputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    name: 'duels',
    outputs: [
      { internalType: 'uint256', name: 'duelId', type: 'uint256' },
      { internalType: 'address', name: 'creator', type: 'address' },
      { internalType: 'address', name: 'challenger', type: 'address' },
      { internalType: 'address', name: 'token', type: 'address' },
      { internalType: 'uint256', name: 'entryStake', type: 'uint256' },
      { internalType: 'uint256', name: 'targetPrice', type: 'uint256' },
      { internalType: 'bool', name: 'isCreatorLong', type: 'bool' },
      { internalType: 'uint256', name: 'entryDeadline', type: 'uint256' },
      { internalType: 'uint256', name: 'settlementTime', type: 'uint256' },
      { internalType: 'uint8', name: 'status', type: 'uint8' },
      { internalType: 'address', name: 'winner', type: 'address' },
      { internalType: 'string', name: 'marketSymbol', type: 'string' },
    ],
    stateMutability: 'view',
    type: 'function',
  },
  {
    inputs: [],
    name: 'nextDuelId',
    outputs: [{ internalType: 'uint256', name: '', type: 'uint256' }],
    stateMutability: 'view',
    type: 'function',
  },
];
