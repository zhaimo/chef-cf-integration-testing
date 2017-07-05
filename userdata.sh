#!/bin/bash
NODE_NAME="$(curl --silent --show-error --retry 3 http://169.254.169.254/latest/meta-data/instance-id)" # This uses the EC2 instance ID as the node name
REGION="us-east-1" # Valid values are us-east-1, us-west-2, or eu-west-1
CHEF_SERVER_NAME="hz-chef" # The name of your Chef server
CHEF_SERVER_ENDPOINT="hz-chef-dlkuvp7xysf9d9uj.us-east-1.opsworks-cm.io/" # Provide the FQDN or endpoint; it's the string after 'https://'

CHEF_ORGANIZATION="default"    # Leave as "default"; do not change. AWS OpsWorks for Chef Automate always creates the organization "default"
NODE_ENVIRONMENT="development"            # e.g. development, staging, onebox ...
CHEF_CLIENT_VERSION="12.19.36" # latest if empty
#RUN_LIST="recipe[chef-client],recipe[apachecookbook]"
RUN_LIST="recipe[fmw_wls::install]"
set -e -o pipefail
AWS_CLI_TMP_FOLDER=$(mktemp --directory "/tmp/awscli_XXXX")
CHEF_CA_PATH="/etc/chef/opsworks-cm-ca-2016-root.pem"
install_aws_cli() {
  cd "$AWS_CLI_TMP_FOLDER"
  curl --retry 3 -L -o "awscli-bundle.zip" "https://s3.amazonaws.com/aws-cli/awscli-bundle.zip"
  unzip "awscli-bundle.zip"
  ./awscli-bundle/install -i "$PWD"
}
aws_cli() {
  "${AWS_CLI_TMP_FOLDER}/bin/aws" opsworks-cm --region "${REGION}" --output text "$@" --server-name "${CHEF_SERVER_NAME}"
}
associate_node() {
  client_key="/etc/chef/client.pem"
  mkdir /etc/chef
  ( umask 077; openssl genrsa -out "${client_key}" 2048 )

  aws_cli associate-node \
    --node-name "${NODE_NAME}" \
    --engine-attributes \
    "Name=CHEF_ORGANIZATION,Value=${CHEF_ORGANIZATION}" \
    "Name=CHEF_NODE_PUBLIC_KEY,Value='$(openssl rsa -in "${client_key}" -pubout)'"
}
write_chef_config() {
  (
    echo "chef_server_url   'https://${CHEF_SERVER_ENDPOINT}/organizations/${CHEF_ORGANIZATION}'"
    echo "node_name         '${NODE_NAME}'"
    echo "ssl_ca_file       '${CHEF_CA_PATH}'"
  ) >> /etc/chef/client.rb
}
install_chef_client() {
  curl --silent --show-error --retry 3 --location https://omnitruck.chef.io/install.sh | bash -s -- -v "${CHEF_CLIENT_VERSION}"
}
install_trusted_certs() {
  curl --silent --show-error --retry 3 --location --output "${CHEF_CA_PATH}" \
    "https://opsworks-cm-${REGION}-prod-default-assets.s3.amazonaws.com/misc/opsworks-cm-ca-2016-root.pem"
}
wait_node_associated() {
  aws_cli wait node-associated --node-association-status-token "$1"
}
install_aws_cli
node_association_status_token="$(associate_node)"
install_chef_client
write_chef_config
install_trusted_certs
wait_node_associated "${node_association_status_token}"
chef-client -r "${RUN_LIST}"
