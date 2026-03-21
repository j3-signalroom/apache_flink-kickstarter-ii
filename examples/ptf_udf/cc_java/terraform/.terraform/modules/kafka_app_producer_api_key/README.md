# IaC Confluent API Key Rotation Terraform module
This Terraform [module](https://developer.hashicorp.com/terraform/language/modules) is designed to manage the creation and rotation of Confluent [API Keys](https://docs.confluent.io/cloud/current/access-management/authenticate/api-keys/api-keys.html). The key rotation is triggered based on the number of days since the key's creation, ensuring that keys are regularly updated for enhanced security. You can also configure the module to retain a specific number of API Keys per [Service Account](https://docs.confluent.io/cloud/current/access-management/identity/service-accounts/overview.html), giving you flexibility in how keys are managed.

A Terraform module is essentially a collection of [input](https://developer.hashicorp.com/terraform/language/values/variables) and [output](https://developer.hashicorp.com/terraform/language/values/outputs) variables, resources, and configuration files that encapsulate specific functionality. By defining input variables, you can customize the module's behavior without altering its source code, making it adaptable to various use cases. Output variables provide information that can be used by other modules or configurations. This modular approach not only promotes reusability and composability but also simplifies the sharing of standardized configurations across different Terraform setups, enabling more efficient and consistent infrastructure management.

**Table of Contents**

<!-- toc -->
+ [1.0 Let's get started!](#10-lets-get-started)
+ [2.0 Resources](#20-resources)
<!-- tocstop -->

## 1.0 Let's get started!

> **Important Notice**
>
> To ensure seamless operation and avoid potential disruptions when using Terraform with time-based rotation, it’s crucial to regularly execute the module within the specified rotation period. Specifically, the execution frequency should match or exceed the configured rotation interval for API key. Failing to adhere to this schedule risks the deletion of multiple key pairs in a single execution cycle. Such an occurrence could potentially remove all active API keys, thereby disrupting any processes that rely on older keys for accessing Snowflake resources. To maintain uninterrupted access and functionality, it is imperative to keep the module execution timely and consistent with the rotation settings.

**These are the steps**

1. Take care of the cloud environment prequisities listed below:
    > You need to have the following cloud accounts:
    > - [Confluent Account](https://confluent.cloud/)
    > - [GitHub Account](https://github.com) *with OIDC configured for AWS*
    > - [Terraform Cloud Account](https://app.terraform.io/)

2. Clone the repo:
    ```shell
    git clone https://github.com/j3-signalroom/iac-snowflake-user-rsa_key_pairs_rotation-tf_module.git
    ```

3.  Deploy your Terraform module to GitHub by following these steps:

	a. **Commit your module:**  Ensure all changes to your Terraform module are committed to your local Git repository.

	b. **Push to GitHub:**  Push your committed changes to your GitHub repository.  This makes the module available for use in other projects.

	c. **Add a Module Block:**  In the Terraform configuration where you want to use the module, add a module block.  Inside this block, include the following:

	*Source*: Reference the GitHub repository URL where your module is stored.

	*Version*: Specify the appropriate branch, tag, or commit hash to ensure you’re using the correct version of the module.

    d. **Pass Input Variables:**  Within the same module block, pass the required input variables by defining them as key-value pairs:
    Input Variable|Variable Required|Description
    -|-|-
    `day_count`|No|[_Defaults to 30 days_]  Specifies how many day(s) should the API Key be rotated for
    `number_of_api_keys_to_retain`|No|[_Defaults to 2 API Keys_]  Specifies the number of API Keys to retain
    `key_display_name`|No|[_Defaults to a display name with current date_]  Specifies the name of the human-readable name for the API Key
    `owner`|Yes|Specifies the API Key Owner.  Refer to [Confluent API Key Docs](https://registry.terraform.io/providers/confluentinc/confluent/latest/docs/resources/confluent_api_key#argument-reference) for more info 
    `resource`|Yes|Specifies the API Key Resource associated with it.  Refer to [Confluent API Key Docs](https://registry.terraform.io/providers/confluentinc/confluent/latest/docs/resources/confluent_api_key#argument-reference) for more details

    e. **Output Variables:**
    Output Variable|Description
    -|-
    `active_api_key`|Specifies the current active API Key to be used for new logins.  Refer to [confluent/confluent_api_key](https://registry.terraform.io/providers/confluentinc/confluent/latest/docs/resources/confluent_api_key) for the expected structure
    `all_api_keys`|Specifies all API Keys sorted by creation date.  With the current active API Key being the 1st in the collection

## 2.0 Resources
[Best Practices for Using API Keys on Confluent Cloud](https://docs.confluent.io/cloud/current/security/authenticate/workload-identities/service-accounts/api-keys/best-practices-api-keys.html)

[Nikoleta Verbeck shows how to use Terraform to rotate Confluent API Key(s)](https://github.com/nerdynick/terraform-confluent-api-key-rotation)

[Terraform Resource time_rotating](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/rotating.html)

[Terraform Hidden Gems! Secret Rotation with time_rotating](https://medium.com/cloud-native-daily/terraform-hidden-gems-secret-rotation-with-time-rotating-72ae8683ef7f)