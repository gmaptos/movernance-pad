# MovernancePad

MovernancePad is a decentralized launchpad platform built on the Movement blockchain. It allows projects to launch token sales and users to participate in Initial DEX Offerings (IDOs) in a fair and transparent manner.

## Features

- Create and manage token sale pools
- Whitelist functionality for early supporters
- Configurable IDO parameters (start time, end time, hard cap, etc.)
- Automatic token distribution and refunds
- Admin controls for pool management

## Getting Started

### Prerequisites

- [Aptos CLI](https://aptos.dev/cli-tools/aptos-cli-tool/install-aptos-cli)
- [Node.js](https://nodejs.org/) (v14 or later)
- [pnpm](https://pnpm.io/) (v8 or later)

### Installation

1. Clone the repository:
   ```
   git clone https://github.com/your-username/movernance-pad.git
   cd movernance-pad
   ```

2. Install dependencies:
   ```
   pnpm install
   ```

3. Copy the example environment file and update it with your settings:
   ```
   cp .env.example .env
   ```

4. Build the Move modules:
   ```
   task build
   ```

5. Run tests:
   ```
   task test
   ```

6. Deploy the modules (make sure you have configured your Aptos account):
   ```
   task publish
   ```

7. Run the demo script:
   ```
   task demo
   ```

## Usage

Refer to the `src/demo.ts` file for example usage of the MovernancePad functions, including creating pools, updating whitelists, and managing token sales.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
