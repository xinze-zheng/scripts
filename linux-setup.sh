
# Setup scripts for new linux environment

# Install gh 
(type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
	&& sudo mkdir -p -m 755 /etc/apt/keyrings \
	&& out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
	&& cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& sudo mkdir -p -m 755 /etc/apt/sources.list.d \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& sudo apt update \
	&& sudo apt install gh -y

# Install copilot
curl -fsSL https://gh.io/copilot-install | bash
grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' ~/.bashrc || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc

# Install miniconda
mkdir -p ~/miniconda3
wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda3/miniconda.sh
bash ~/miniconda3/miniconda.sh -b -u -p ~/miniconda3
rm ~/miniconda3/miniconda.sh
~/miniconda3/bin/conda init bash

# Install uv
curl -LsSf https://astral.sh/uv/install.sh | sh


# SkyRL & UCCL
mkdir -p ~/skyrl
mkdir -p ~/uccl
sudo apt update && sudo apt-get install -y build-essential libnuma-dev libibverbs-dev 

cd ~/skyrl
git clone https://github.com/NovaSky-AI/SkyRL.git
cd SkyRL
uv venv
source .venv/bin/activate
uv sync --active --extra fsdp
deactivate

cd ~/uccl
git clone https://github.com/uccl-project/uccl.git
cd uccl
./install_deps.sh
python setup.py install

git config --global user.email wxzheng@berkeley.edu
git config --global user.name xinze-zheng