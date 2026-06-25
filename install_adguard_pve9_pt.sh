#!/usr/bin/env bash
# =========================================================================================
# Instalação Automatizada do AdGuard Home (LXC) para Proxmox VE 9+
# =========================================================================================
# Este script cria um container LXC levíssimo usando o template do Debian,
# configura a rede e executa a instalação oficial do AdGuard Home.
# =========================================================================================

set -e # Interrompe o script se houver qualquer erro

echo -e "\n🟢 Iniciando o Proxmox 9 AdGuard Home LXC Builder..."

# 1. Coleta de Variáveis Básicas
read -p "Digite o ID numérico para o novo LXC (ex: 105): " CT_ID
read -p "Digite a interface de ponte de rede (ex: vmbr1 para o Lab, ou vmbr0 para LAN): " CT_BRIDGE
read -p "Digite o IP estático com máscara (ex: 10.0.0.53/24) ou 'dhcp': " CT_IP
if [ "$CT_IP" != "dhcp" ]; read -p "Digite o Gateway (ex: 10.0.0.1): " CT_GW; fi

CT_NAME="AdGuard-Home"
CT_RAM=512
CT_CORES=1
CT_DISK=4

# 2. Atualização e Download do Template do Debian
echo -e "\n⏳ Atualizando lista de templates do Proxmox..."
pveam update >/dev/null

echo "⏳ Buscando o template padrão do Debian..."
TEMPLATE=$(pveam available -section system | grep 'debian-12-standard\|debian-13-standard' | awk '{print $2}' | tail -n 1)

if [ -z "$TEMPLATE" ]; then
    echo "❌ Erro: Template do Debian não encontrado no Proxmox."
    exit 1
fi

echo "📥 Baixando $TEMPLATE (Isso pode levar alguns minutos)..."
pveam download local $TEMPLATE >/dev/null

# 3. Construção do LXC
echo -e "\n🛠️ Construindo o Container LXC $CT_ID..."
if [ "$CT_IP" == "dhcp" ]; then
    pct create $CT_ID local:vztmpl/$(basename $TEMPLATE) \
        --ostype debian --arch amd64 \
        --hostname $CT_NAME \
        --cores $CT_CORES --memory $CT_RAM --swap 0 \
        --rootfs local-lvm:${CT_DISK} \
        --net0 name=eth0,bridge=${CT_BRIDGE},ip=dhcp \
        --unprivileged 1 \
        --features nesting=1
else
    pct create $CT_ID local:vztmpl/$(basename $TEMPLATE) \
        --ostype debian --arch amd64 \
        --hostname $CT_NAME \
        --cores $CT_CORES --memory $CT_RAM --swap 0 \
        --rootfs local-lvm:${CT_DISK} \
        --net0 name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW} \
        --unprivileged 1 \
        --features nesting=1
fi

# 4. Inicialização e Configuração
echo "🚀 Iniciando o LXC..."
pct start $CT_ID
echo "⏳ Aguardando a rede subir (10 segundos)..."
sleep 10

echo "📦 Atualizando pacotes no container e instalando curl/sudo..."
pct exec $CT_ID -- apt-get update -y >/dev/null
pct exec $CT_ID -- apt-get install -y curl sudo >/dev/null

# 5. Instalação Oficial do AdGuard Home
echo "🛡️ Instalando o AdGuard Home..."
pct exec $CT_ID -- bash -c "curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v"

# 6. Conclusão
echo -e "\n======================================================================"
echo "✅ Instalação Concluída com Sucesso no Proxmox 9!"
echo "======================================================================"
if [ "$CT_IP" == "dhcp" ]; then
    echo "Como você escolheu DHCP, verifique o IP que o roteador atribuiu."
    echo "Acesse no navegador: http://<IP_DO_LXC>:3000"
else
    # Extrai apenas o IP sem a máscara para exibir a URL final
    CLEAN_IP=$(echo $CT_IP | cut -d'/' -f1)
    echo "Acesse o painel de configuração inicial em:"
    echo "👉 http://${CLEAN_IP}:3000"
fi
echo "======================================================================"
