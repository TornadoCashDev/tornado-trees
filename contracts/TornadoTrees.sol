// SPDX-License-Identifier: MIT

pragma solidity ^0.6.0;
pragma experimental ABIEncoderV2;

import "./interfaces/ITornadoTreesV1.sol";
import "./interfaces/IBatchTreeUpdateVerifier.sol";

contract TornadoTrees {
  address public immutable governance;
  bytes32 public depositRoot;
  bytes32 public previousDepositRoot;
  bytes32 public withdrawalRoot;
  bytes32 public previousWithdrawalRoot;
  address public tornadoProxy;
  IBatchTreeUpdateVerifier public treeUpdateVerifier;
  ITornadoTreesV1 public immutable tornadoTreesV1;

  // make sure CHUNK_TREE_HEIGHT has the same value in BatchTreeUpdate.circom
  uint256 public constant CHUNK_TREE_HEIGHT = 2;
  uint256 public constant CHUNK_SIZE = 2**CHUNK_TREE_HEIGHT;
  uint256 public constant ITEM_SIZE = 32 + 20 + 4;
  uint256 public constant BYTES_SIZE = 32 + 32 + 4 + CHUNK_SIZE * ITEM_SIZE;
  uint256 public constant SNARK_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

  mapping(uint256 => bytes32) public deposits;
  uint256 public depositsLength;
  uint256 public lastProcessedDepositLeaf;
  uint256 public immutable depositV1Length;

  mapping(uint256 => bytes32) public withdrawals;
  uint256 public withdrawalsLength;
  uint256 public lastProcessedWithdrawalLeaf;
  uint256 public immutable withdrawalsV1Length;

  event DepositData(address instance, bytes32 indexed hash, uint256 block, uint256 index);
  event WithdrawalData(address instance, bytes32 indexed hash, uint256 block, uint256 index);

  struct TreeLeaf {
    bytes32 hash;
    address instance;
    uint32 block;
  }

  struct Batch {
    bytes32 oldRoot;
    bytes32 newRoot;
    uint8 pathIndices;
    TreeLeaf[CHUNK_SIZE] events;
  }

  modifier onlyTornadoProxy {
    require(msg.sender == tornadoProxy, "Not authorized");
    _;
  }

  modifier onlyGovernance() {
    require(msg.sender == governance, "Only governance can perform this action");
    _;
  }

  struct SearchParams {
    uint256 unprocessedDeposits;
    uint256 unprocessedWithdrawals;
    uint256 depositsPerDay;
    uint256 withdrawalsPerDay;
  }

  constructor(
    address _governance,
    address _tornadoProxy,
    ITornadoTreesV1 _tornadoTreesV1,
    IBatchTreeUpdateVerifier _treeUpdateVerifier,
    SearchParams memory _searchParams
  ) public {
    governance = _governance;
    tornadoProxy = _tornadoProxy;
    treeUpdateVerifier = _treeUpdateVerifier;
    tornadoTreesV1 = _tornadoTreesV1;

    depositRoot = _tornadoTreesV1.depositRoot();
    uint256 lastDepositLeaf = _tornadoTreesV1.lastProcessedDepositLeaf();
    require(lastDepositLeaf % CHUNK_SIZE == 0, "Incorrect TornadoTrees state");
    lastProcessedDepositLeaf = lastDepositLeaf;
    depositsLength = depositV1Length = findArrayLength(
      _tornadoTreesV1,
      "deposits(uint256)",
      _searchParams.unprocessedDeposits,
      _searchParams.depositsPerDay
    );

    withdrawalRoot = _tornadoTreesV1.withdrawalRoot();
    uint256 lastWithdrawalLeaf = _tornadoTreesV1.lastProcessedWithdrawalLeaf();
    require(lastWithdrawalLeaf % CHUNK_SIZE == 0, "Incorrect TornadoTrees state");
    lastProcessedWithdrawalLeaf = lastWithdrawalLeaf;
    withdrawalsLength = withdrawalsV1Length = findArrayLength(
      _tornadoTreesV1,
      "withdrawals(uint256)",
      _searchParams.unprocessedWithdrawals,
      _searchParams.withdrawalsPerDay
    );
  }

  // todo make things internal
  /// @dev There is no array length getter for deposit and withdrawal arrays
  /// in previous contract, so we have to find them length manually
  function findArrayLength(
    ITornadoTreesV1 _tornadoTreesV1,
    string memory _type,
    uint256 _from, // most likely array length after the proposal has passed
    uint256 _step // optimal step size to find first match, approximately equals dispersion
  ) public view returns (uint256) {
    // Find the segment with correct array length
    bool direction = elementExists(_tornadoTreesV1, _type, _from);
    do {
      _from = direction ? _from + _step : _from - _step;
    } while (direction == elementExists(_tornadoTreesV1, _type, _from));
    uint256 high = direction ? _from : _from + _step;
    uint256 low = direction ? _from - _step : _from;
    uint256 mid = (high + low) / 2;

    // Perform a binary search in this segment
    while (low < mid) {
      if (elementExists(_tornadoTreesV1, _type, mid)) {
        low = mid;
      } else {
        high = mid;
      }
      mid = (low + high) / 2;
    }
    return mid + 1;
  }

  function elementExists(
    ITornadoTreesV1 _tornadoTreesV1,
    string memory _type,
    uint256 index
  ) public view returns (bool success) {
    // Try to get the element. If it succeeds the array length is higher, it it reverts the length is equal or lower
    (success, ) = address(_tornadoTreesV1).staticcall{ gas: 2500 }(abi.encodeWithSignature(_type, index));
  }

  function registerDeposit(address _instance, bytes32 _commitment) public onlyTornadoProxy {
    uint256 _depositsLength = depositsLength;
    deposits[_depositsLength] = keccak256(abi.encode(_instance, _commitment, blockNumber()));
    emit DepositData(_instance, _commitment, blockNumber(), _depositsLength);
    depositsLength = _depositsLength + 1;
  }

  function registerWithdrawal(address _instance, bytes32 _nullifierHash) public onlyTornadoProxy {
    uint256 _withdrawalsLength = withdrawalsLength;
    withdrawals[_withdrawalsLength] = keccak256(abi.encode(_instance, _nullifierHash, blockNumber()));
    emit WithdrawalData(_instance, _nullifierHash, blockNumber(), _withdrawalsLength);
    withdrawalsLength = _withdrawalsLength + 1;
  }

  function updateDepositTree(
    bytes calldata _proof,
    bytes32 _argsHash,
    bytes32 _currentRoot,
    bytes32 _newRoot,
    uint32 _pathIndices,
    TreeLeaf[CHUNK_SIZE] calldata _events
  ) public {
    uint256 offset = lastProcessedDepositLeaf;
    require(_newRoot != previousDepositRoot, "Outdated deposit root");
    require(_currentRoot == depositRoot, "Proposed deposit root is invalid");
    require(_pathIndices == offset >> CHUNK_TREE_HEIGHT, "Incorrect insert index");

    bytes memory data = new bytes(BYTES_SIZE);
    assembly {
      mstore(add(data, 0x44), _pathIndices)
      mstore(add(data, 0x40), _newRoot)
      mstore(add(data, 0x20), _currentRoot)
    }
    for (uint256 i = 0; i < CHUNK_SIZE; i++) {
      (bytes32 hash, address instance, uint32 blockNumber) = (_events[i].hash, _events[i].instance, _events[i].block);
      bytes32 leafHash = keccak256(abi.encode(instance, hash, blockNumber));
      bytes32 deposit = offset + i >= depositV1Length ? deposits[offset + i] : tornadoTreesV1.deposits(offset + i);
      require(leafHash == deposit, "Incorrect deposit");
      assembly {
        mstore(add(add(data, mul(ITEM_SIZE, i)), 0x7c), blockNumber)
        mstore(add(add(data, mul(ITEM_SIZE, i)), 0x78), instance)
        mstore(add(add(data, mul(ITEM_SIZE, i)), 0x64), hash)
      }
      if (offset + i >= depositV1Length) {
        delete deposits[offset + i];
      } else {
        emit DepositData(instance, hash, blockNumber, offset + i);
      }
    }

    uint256 argsHash = uint256(sha256(data)) % SNARK_FIELD;
    require(argsHash == uint256(_argsHash), "Invalid args hash");
    require(treeUpdateVerifier.verifyProof(_proof, [argsHash]), "Invalid deposit tree update proof");

    previousDepositRoot = _currentRoot;
    depositRoot = _newRoot;
    lastProcessedDepositLeaf = offset + CHUNK_SIZE;
  }

  function updateWithdrawalTree(
    bytes calldata _proof,
    bytes32 _argsHash,
    bytes32 _currentRoot,
    bytes32 _newRoot,
    uint256 _pathIndices,
    TreeLeaf[CHUNK_SIZE] calldata _events
  ) public {
    uint256 offset = lastProcessedWithdrawalLeaf;
    require(_newRoot != previousWithdrawalRoot, "Outdated withdrawal root");
    require(_currentRoot == withdrawalRoot, "Proposed withdrawal root is invalid");
    require(_pathIndices == offset >> CHUNK_TREE_HEIGHT, "Incorrect insert index");
    require(uint256(_newRoot) < SNARK_FIELD, "Proposed root is out of range");

    bytes memory data = new bytes(BYTES_SIZE);
    assembly {
      mstore(add(data, 0x44), _pathIndices)
      mstore(add(data, 0x40), _newRoot)
      mstore(add(data, 0x20), _currentRoot)
    }
    for (uint256 i = 0; i < CHUNK_SIZE; i++) {
      (bytes32 hash, address instance, uint32 blockNumber) = (_events[i].hash, _events[i].instance, _events[i].block);
      bytes32 leafHash = keccak256(abi.encode(instance, hash, blockNumber));
      bytes32 withdrawal = offset + i >= withdrawalsV1Length ? withdrawals[offset + i] : tornadoTreesV1.withdrawals(offset + i);
      require(leafHash == withdrawal, "Incorrect withdrawal");
      require(uint256(hash) < SNARK_FIELD, "Hash out of range");
      assembly {
        mstore(add(add(data, mul(ITEM_SIZE, i)), 0x7c), blockNumber)
        mstore(add(add(data, mul(ITEM_SIZE, i)), 0x78), instance)
        mstore(add(add(data, mul(ITEM_SIZE, i)), 0x64), hash)
      }
      if (offset + i >= withdrawalsV1Length) {
        delete withdrawals[offset + i];
      } else {
        emit WithdrawalData(instance, hash, blockNumber, offset + i);
      }
    }

    uint256 argsHash = uint256(sha256(data)) % SNARK_FIELD;
    require(argsHash == uint256(_argsHash), "Invalid args hash");
    require(treeUpdateVerifier.verifyProof(_proof, [argsHash]), "Invalid withdrawal tree update proof");

    previousWithdrawalRoot = _currentRoot;
    withdrawalRoot = _newRoot;
    lastProcessedWithdrawalLeaf = offset + CHUNK_SIZE;
  }

  function validateRoots(bytes32 _depositRoot, bytes32 _withdrawalRoot) public view {
    require(_depositRoot == depositRoot || _depositRoot == previousDepositRoot, "Incorrect deposit tree root");
    require(_withdrawalRoot == withdrawalRoot || _withdrawalRoot == previousWithdrawalRoot, "Incorrect withdrawal tree root");
  }

  function getRegisteredDeposits() external view returns (bytes32[] memory _deposits) {
    uint256 count = depositsLength - lastProcessedDepositLeaf;
    _deposits = new bytes32[](count);
    for (uint256 i = 0; i < count; i++) {
      _deposits[i] = deposits[lastProcessedDepositLeaf + i];
    }
  }

  function getRegisteredWithdrawals() external view returns (bytes32[] memory _withdrawals) {
    uint256 count = withdrawalsLength - lastProcessedWithdrawalLeaf;
    _withdrawals = new bytes32[](count);
    for (uint256 i = 0; i < count; i++) {
      _withdrawals[i] = withdrawals[lastProcessedWithdrawalLeaf + i];
    }
  }

  function setTornadoProxyContract(address _tornadoProxy) external onlyGovernance {
    tornadoProxy = _tornadoProxy;
  }

  function setVerifierContract(IBatchTreeUpdateVerifier _treeUpdateVerifier) external onlyGovernance {
    treeUpdateVerifier = _treeUpdateVerifier;
  }

  function blockNumber() public view virtual returns (uint256) {
    return block.number;
  }
}
