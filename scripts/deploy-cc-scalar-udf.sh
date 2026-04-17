#!/bin/bash

#
# *** Script Syntax ***
# ./deploy-cc-scalar-udf.sh=<create | destroy> --confluent-api-key=<CONFLUENT_API_KEY>
#                                              --confluent-api-secret=<CONFLUENT_API_SECRET>
#                                              [--day-count=<DAY_COUNT>]
#
#

set -euo pipefail  # Stop on error, undefined variables, and pipeline errors

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NO_COLOR='\033[0m'

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NO_COLOR} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NO_COLOR} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NO_COLOR} $1"
}

print_step() {
    echo -e "${BLUE}[STEP]${NO_COLOR} $1"
}

# Configuration folders
TERRAFORM_DIR="$(cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../examples/ptf_udf_row_driven/cc_deploy" && pwd)"
MAKEFILE_DIR="$(cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../" && pwd)"

print_info "Terraform Directory: $TERRAFORM_DIR"
print_info "Makefile Directory: $MAKEFILE_DIR"

argument_list="--confluent-api-key=<CONFLUENT_API_KEY> --confluent-api-secret=<CONFLUENT_API_SECRET>"


# Check required command (create or destroy) was supplied
case $1 in
  create)
    create_action=true;;
  destroy)
    create_action=false;;
  *)
    echo
    print_error "(Error Message 001)  You did not specify one of the commands: create | destroy."
    echo
    print_error "Usage:  Require all two arguments ---> `basename $0`=<create | destroy> $argument_list"
    echo
    exit 85 # Common GNU/Linux Exit Code for 'Interrupted system call should be restarted'
    ;;
esac

# Default optional variables
day_count=30

# Get the arguments passed by shift to remove the first word
# then iterate over the rest of the arguments
shift
for arg in "$@" # $@ sees arguments as separate words
do
    case $arg in
        *"--confluent-api-key="*)
            arg_length=20
            confluent_api_key=${arg:$arg_length:$(expr ${#arg} - $arg_length)};;
        *"--confluent-api-secret="*)
            arg_length=23
            confluent_api_secret=${arg:$arg_length:$(expr ${#arg} - $arg_length)};;
        *)
            echo
            print_error "(Error Message 002)  You included an invalid argument: $arg"
            echo
            print_error "Usage:  Require all two arguments ---> `basename $0`=<create | destroy> $argument_list"
            echo
            exit 85 # Common GNU/Linux Exit Code for 'Interrupted system call should be restarted'
            ;;
    esac
done

# Check required --confluent-api-key argument was supplied
if [ -z $confluent_api_key ]
then
    echo
    print_error "(Error Message 003)  You did not include the proper use of the --confluent-api-key=<CONFLUENT_API_KEY> argument in the call."
    echo
    print_error "Usage:  Require all fourteen arguments ---> `basename $0 $1` $argument_list"
    echo
    exit 85 # Common GNU/Linux Exit Code for 'Interrupted system call should be restarted'
fi

# Check required --confluent-api-secret argument was supplied
if [ -z $confluent_api_secret ]
then
    echo
    print_error "(Error Message 004)  You did not include the proper use of the --confluent-api-secret=<CONFLUENT_API_SECRET> argument in the call."
    echo
    print_error "Usage:  Require all fourteen arguments ---> `basename $0 $1` $argument_list"
    echo
    exit 85 # Common GNU/Linux Exit Code for 'Interrupted system call should be restarted'
fi


# Export variables for Terraform
export TF_VAR_confluent_api_key="${confluent_api_key}"
export TF_VAR_confluent_api_secret="${confluent_api_secret}"
export TF_VAR_day_count="${day_count}"

cd "$TERRAFORM_DIR"

# Initialize the Terraform configuration
terraform init

if [ "$create_action" = true ]
then
    print_info "Applying Terraform..."
    terraform apply -auto-approve
    print_info "Infrastructure deployed successfully!"

    print_info "Creating the Terraform visualization..."
    terraform graph | dot -Tpng > "$TERRAFORM_DIR/terraform.png"
    print_info "Terraform visualization created at: $TERRAFORM_DIR/terraform.png"
else
    # Destroy
    print_info "Running Terraform destroy..."
    
    # Auto approves the destroy plan without prompting, and destroys based on state only, without
    # trying to refresh data sources
    terraform destroy -auto-approve
fi

cd "$MAKEFILE_DIR"