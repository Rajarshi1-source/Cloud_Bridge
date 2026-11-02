# Go live on Google Cloud, AWS and Cloudflare: a beginner's guide

This guide assumes you have never used a cloud account or deployed anything. Follow it from top to
bottom and don't skip parts. At the end, `https://app.<your-domain>` will be on the public internet,
with about 70% of visitors served from AWS and 30% from Google Cloud.

**Plan on one or two days.** Most of that is waiting for account checks, not typing.

> **Be aware:** these steps have never been run against real accounts. The code passes its offline
> tests and runs on your PC in the local twin, but a first real run can still hit errors. That's why
> this guide goes one small step at a time. If something fails, stop and copy the error into Claude
> (remove any passwords, keys or tokens first). Part 11 lists the likely errors.

---

## Part 1: What you're building

### The idea in plain words

- **A cloud** is a company renting you computers by the hour. You'll rent one small computer from AWS
  and one from Google Cloud, both in Mumbai.
- **A cell** is one complete copy of your app, with its own database, on one of those computers.
- **Cloudflare** stands in front of both cells. Each visitor reaches Cloudflare first, and it sends
  them to a healthy cell. If one cloud goes down, visitors go to the other.
- **A domain** is the name people type, such as `example.com`. You need to own one.

```
                     Visitors
                        │
                        ▼
            Cloudflare Load Balancer
             app.<your-domain>
              │                 │
          70% │                 │ 30%
              ▼                 ▼
         AWS computer      Google computer
          (Mumbai)            (Mumbai)
          full app            full app
```

### The tools, and what each one does

You won't run these by hand very often. The commands in this guide call them for you.

| Tool | What it does |
|---|---|
| **Terraform** | Rents the computers, networks and load balancer, using the files in `infra/` |
| **Ansible** | Logs in to each computer and sets it up, using the files in `ansible/` |
| **k3s** | A small Kubernetes, which runs your app's containers on each computer |
| **Argo CD** | Runs inside each cell and installs your app, reading `gitops/` from GitHub's `main` branch |
| **Docker Hub** | Stores your app's images, which the cells download |

### What it costs

Prices were last checked on 16 Oct 2026 and are estimates. Check the screen before you confirm anything.

| Item | Rough cost | Who pays |
|---|---|---|
| AWS computer, disk and address | About US$23/month | AWS free credits |
| Google computer, disk and address | About US$20–25/month | Google free credit |
| Cloudflare account and DNS | US$0 | Free |
| **Cloudflare Load Balancing** | **From US$5/month** | **You, real money** |
| **Domain name** | **About US$10–15/year** | **You, real money** |
| Zero Trust (Cloudflare) | US$0, but it asks for a card | Free for up to 50 users |

### Can I avoid the US$5 load balancer?

You'll find free alternatives online. Cloudflare's Load Balancing has no free tier, so they're fair to
ask about. **For this project, the US$5 is still the right choice**, because of how this app works:
each cell has its own database. A visitor who places an order on AWS must stay on AWS, or their order
seems to vanish. That's what the load balancer's cookie does.

| Free idea | Why it doesn't fit CloudBridge |
|---|---|
| **A Cloudflare Worker** that picks a cloud at random (100,000 requests a day free) | The only real alternative, but it's new code to write and test. Simple examples online split 50/50 with no cookie, so visitors bounce between databases. They have no regular health checks. Retrying a failed order could also place it twice. And the weights, failover and drills planned for Weeks 6–8 all build on the load balancer |
| **AWS or Google's own load balancer** behind Cloudflare | Each one only balances inside its own cloud, so it can't split traffic between AWS and Google. It isn't free either: AWS's "750 free hours" belongs to the old free tier, and new accounts get credits instead |
| **Cloudflare Pages** as a backup | Only for static websites. This app is an API with databases, and switching over means changing DNS by hand |
| **Two free DNS records** (round robin) | No weights, no regular health checks and no cookie |

The free computers those guides suggest (`t2.micro`, `e2-micro`) won't work either. They have 1 GB of
memory, and a cell needs 2 GB. Google's free `e2-micro` also isn't offered in Mumbai.

If US$5 a month is ever truly out of reach, the Worker is the route to take, but plan it as its own piece of
work first. Don't copy an example into production.

### Free offers have end dates

These clocks **start the day you sign up**, not the day you deploy. Do Part 3 and Part 6 close together.

| Offer | What you get | When it ends |
|---|---|---|
| **Google Free Trial** | US$300 credit, and you aren't billed unless you upgrade | After **90 days**, resources stop, then get deleted after a 30-day grace period |
| **AWS Free plan** | US$100 credit (up to US$100 more for activities), and you can't be charged | After **6 months** or when the credit runs out, the account closes, and data is deleted after 90 days |

Write both end dates in your calendar on the day you sign up.

### Things you need before you start

- [ ] A bank card with online and international payments turned on (needed by all three companies)
- [ ] A phone that can receive SMS
- [ ] Your GitHub login and your Docker Hub login (`rickyenrico01`)
- [ ] An authenticator app on your phone, such as Google Authenticator

---

## Part 2: Safety rules and the terminal

### Four rules

1. **Never paste a password, key or token** into a chat, GitHub, a commit or a command. When this
   guide needs a secret, it uses `read -rs`, which keeps it out of your command history.
2. **`read -rs` shows nothing while you paste.** That's normal. Paste once and press Enter.
3. **Before running a command, replace nothing unless told to.** Values are read from a settings
   file you'll make in a moment, so most commands work exactly as written.
4. **If a command prints an error, stop.** Don't run the next one. Go to Part 11.

### Open the right terminal

Almost everything runs in your Ubuntu-D Linux terminal, not in Windows. Open PowerShell and run this:

```powershell
wsl -d Ubuntu-D --cd "/mnt/d/New Projects/Cloud_Bridge"
```

Your prompt should now end in `Cloud_Bridge$`. **Part 3 and later assume you are here.** Closing the
window is fine; just open it again the same way.

### Free up memory

The local twin uses about 5 GB of memory, so stop it while you deploy. Your data is kept:

```bash
bash tools/dev/twin.sh down
```

### Install the tools (one time, about 10 minutes)

This installs Terraform, Ansible, the AWS and Google command-line tools and kubectl. It checks each
download's signature or checksum. It may ask for your Linux password; nothing shows as you type.

```bash
bash tools/dev/install-deploy-tools.sh
```

It should finish with `Done.` and a list of versions.

### Make your settings file

This file holds values that aren't secret, so you don't retype them. Create it now:

```bash
cat > ~/cloudbridge-go-live.env <<'EOF'
export GCP_PROJECT_ID="FILL-IN-PART-3"
export UNIQUE="FILL-IN-PART-3"
export DOMAIN="FILL-IN-PART-7"
export CF_ZONE_ID="FILL-IN-PART-7"
export CF_ACCOUNT_ID="FILL-IN-PART-7"
export GCP_OSLOGIN_USER="FILL-IN-PART-6"
export GCP_BUCKET="cb-tfstate-gcp-$UNIQUE"
export AWS_BUCKET="cb-tfstate-aws-$UNIQUE"
export CB_HOSTNAME="app.$DOMAIN"
EOF
```

### Your routine for every new terminal

**Each time you open a new terminal for this guide, run these two lines first.** If you forget, you'll
get `command not found` or empty values.

```bash
source ~/.venvs/cloudbridge/bin/activate
```

```bash
source ~/cloudbridge-go-live.env
```

### Start a branch for your changes

Your edits should go through a pull request, like all the other work in this project. Open a **second,
normal PowerShell window** (not Linux) and run the three lines below, one at a time. Keep that window
for the git steps in Part 8.

```powershell
cd "D:\New Projects\Cloud_Bridge"
```

```powershell
git switch main; git pull
```

```powershell
git switch -c go-live-values
```

---

## Part 3: Create your Google Cloud account

### 3.1 Sign up

1. Go to <https://console.cloud.google.com/freetrial> and sign in with your Google account.
2. Choose **India** and accept the terms. Enter your card. Google uses it to check you're a real
   person. A small amount may be held briefly and returned.
3. **Don't click "Upgrade" or "Activate full account"**, now or later. Staying on the trial is what
   stops you being billed.

Google's docs say accounts in India need a billing account in Indian rupees (INR). Accept that if asked.

### 3.2 Create a project

A project is a folder for everything you rent from Google.

1. At the top of the console, click the project picker, then **New project**.
2. Name it `cloudbridge`.
3. Under the name, note the **Project ID**, for example `cloudbridge-481207`. The ID is what you need,
   not the name.

### 3.3 Set a spending alert

1. Search for **Budgets & alerts** in the top bar and click **Create budget**.
2. Set the amount to US$100 (or the same in rupees), with alerts at 50%, 80% and 100%.

An alert only emails you. It doesn't stop anything.

### 3.4 Fill in your settings file

Pick a short word of lowercase letters and numbers to make your storage names unique, such as `raj42`.
Open the file:

```bash
nano ~/cloudbridge-go-live.env
```

Replace the `FILL-IN-PART-3` values on the `GCP_PROJECT_ID` and `UNIQUE` lines. To save, press
**Ctrl+O**, then **Enter**, then **Ctrl+X**. Then reload it:

```bash
source ~/cloudbridge-go-live.env
```

### 3.5 Connect the terminal to Google

Each `login` command prints a link. Open it in your browser, sign in and allow access. If it gives you
a code, paste it back into the terminal.

```bash
gcloud auth login
```

```bash
gcloud config set project "$GCP_PROJECT_ID"
```

```bash
gcloud auth application-default login
```

The first login is for the `gcloud` tool, and the second is for Terraform and Ansible.

### 3.6 Turn on the services

Google services are off until you turn them on. This takes a minute or two:

```bash
gcloud services enable compute.googleapis.com iam.googleapis.com secretmanager.googleapis.com iap.googleapis.com cloudresourcemanager.googleapis.com container.googleapis.com artifactregistry.googleapis.com
```

### 3.7 Make a storage bucket for Terraform's notes

Terraform keeps a record of everything it created, called its **state**. It lives in a storage bucket
you create now. Bucket names must be unique across all of Google, which is why you chose `UNIQUE`.

```bash
gcloud storage buckets create "gs://$GCP_BUCKET" --location=asia-south1 --uniform-bucket-level-access --public-access-prevention
```

```bash
gcloud storage buckets update "gs://$GCP_BUCKET" --versioning
```

If it says the name is taken, change `UNIQUE` in your settings file, reload it and try again.

### 3.8 Put your values into the project files

```bash
grep -rl --exclude-dir=.terraform '"cb-tfstate-gcp"' infra | xargs -r sed -i "s/\"cb-tfstate-gcp\"/\"$GCP_BUCKET\"/g"
```

```bash
grep -rl --exclude-dir=.terraform cloudbridge-budget-REPLACE-ME infra | xargs -r sed -i "s/cloudbridge-budget-REPLACE-ME/$GCP_PROJECT_ID/g"
```

These commands only print something if there's a problem. It's safe to run them twice.

---

## Part 4: The practice run on Google Cloud (about 2 hours, recommended)

Before spending real money, rent a temporary Google cluster and delete it again. It costs about
US$0.30 in total from your free credit, not from your card.

### What this does and doesn't prove

| It proves | It doesn't prove |
|---|---|
| Your Google account, billing and logins work | Anything on AWS |
| Terraform can save its state to your bucket | The small computers the real go-live uses |
| Terraform can create and delete real resources | Ansible logging in and setting a computer up |
| You can check the result, then tear everything down | Cloudflare, or your app running (it doesn't deploy the app) |

> **Correction:** I told you earlier this one check would catch most of the unproven parts. It
> catches the Google and Terraform problems, but not those in the right-hand column. Those are why
> Part 9 goes one step at a time and checks each one.

### Step 1: Start it

`TTL=2` marks the cluster to expire after 2 hours. **This creates everything straight away, with no
question first**, and takes about 10–20 minutes.

```bash
make -C infra managed-up CLOUD=gcp TTL=2
```

It worked if the last line starts with `Healthy. Reaped after`, and you see two nodes marked `Ready`.

### Step 2: Look at it

Open <https://console.cloud.google.com/kubernetes/list> in your browser. Your cluster is there: real,
and paid for by the credit. You can check it from the terminal any time as well:

```bash
make -C infra managed-check CLOUD=gcp
```

### Step 3: Delete it (you must do this yourself)

> **Important correction:** I said earlier that the "TTL reaper" cleans up automatically. That's only
> true once the GitHub identities from `docs/runbooks/week-3-ephemeral-managed.md` are set up. They
> aren't, so **nothing deletes this cluster for you**, and it keeps using credit until you do.

Run this, read the list, and type `yes` when asked:

```bash
make -C infra managed-down CLOUD=gcp
```

It worked if it ends with `Destroy complete!`. Do this even if Step 1 failed partway, because some
parts may have been created. Then confirm nothing is left. This should print no clusters:

```bash
gcloud container clusters list
```

**Passed?** Your Google setup and Terraform work. Continue to Part 5.
**Failed?** Good: you found it for about 30 cents. See Part 11.

---

## Part 5: Create your AWS account

### 5.1 Sign up

1. Go to <https://aws.amazon.com/free> and click to create an account.
2. Enter your details, card and phone number. Accounts in India are run by an AWS company called
   AISPL, and I couldn't confirm whether the sign-up differs because of that.
3. **Choose the Free account plan.** This is the part that means you can't be charged. If you don't
   see a Free plan option, stop and ask, because the budget alert would then be your only warning.
4. Choose the Basic (free) support plan.
5. The account can take a while to activate. Wait for the confirmation email.

**Don't create an AWS Organization or turn on IAM Identity Center.** Joining an Organization
automatically moves a Free plan account to the Paid plan.

### 5.2 Protect the main login

The email login you just made is the **root** account, and it can do anything.

1. Sign in, click your account name at the top right, then **Security credentials**.
2. Under **Multi-factor authentication**, add your authenticator app.

### 5.3 Check your plan and add an alert

1. Search for **Billing and Cost Management** and open **Free Tier**. Confirm the plan and note the end
   date in your calendar.
2. Open **Budgets**, then **Create budget**, a monthly cost budget with alerts at 50%, 80% and 100%.

### 5.4 Make a login for the terminal

Don't use the root account in the terminal. Create a separate user:

1. Search for **IAM**, then choose **Users** and **Create user**.
2. Name it `cloudbridge-admin`. Leave console access off.
3. Choose **Attach policies directly**, tick **AdministratorAccess**, and create the user.
4. Open the user, go to **Security credentials**, and click **Create access key**.
5. Choose **Command Line Interface (CLI)**. **Keep this page open.** The secret is shown only once.

That key can do almost anything in your account, so treat it like a bank password.

### 5.5 Connect the terminal to AWS

Run this and paste each value when asked. Use `ap-south-1` for the region and `json` for the output.

```bash
aws configure
```

Check it worked. You should see your account number and `cloudbridge-admin`:

```bash
aws sts get-caller-identity
```

Now you can close the key page.

### 5.6 Make the AWS storage bucket

```bash
aws s3api create-bucket --bucket "$AWS_BUCKET" --region ap-south-1 --create-bucket-configuration LocationConstraint=ap-south-1
```

```bash
aws s3api put-bucket-versioning --bucket "$AWS_BUCKET" --versioning-configuration Status=Enabled
```

```bash
aws s3api put-public-access-block --bucket "$AWS_BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Then put the name into the project files:

```bash
grep -rl --exclude-dir=.terraform '"cb-tfstate-aws"' infra | xargs -r sed -i "s/\"cb-tfstate-aws\"/\"$AWS_BUCKET\"/g"
```

---

## Part 6: Give both clouds what they need

### 6.1 A Docker Hub token

The cells log in to Docker Hub to download your app. Give them a token that can only read.

1. Go to <https://hub.docker.com>, then **Account settings → Personal access tokens**.
2. If any old token was ever pasted into a chat or a file, **delete it now**. A token has been pasted
   in this project before.
3. Click **Generate new token** and choose **Public Repo Read-only**. Keep the page open.

Store it in both clouds. Run the first command, paste the token (nothing shows) and press Enter:

```bash
read -rs PULL_TOKEN
```

```bash
printf %s "$PULL_TOKEN" | aws secretsmanager create-secret --region ap-south-1 --name cb/dockerhub-pull --secret-string file:///dev/stdin
```

```bash
gcloud services enable secretmanager.googleapis.com && printf %s "$PULL_TOKEN" | gcloud secrets create cb-dockerhub-pull --replication-policy=automatic --data-file=-
```

```bash
unset PULL_TOKEN
```

Now tell your settings file your Docker Hub name:

```bash
echo 'export DOCKERHUB_USER="rickyenrico01"' >> ~/cloudbridge-go-live.env
```

### 6.2 An SSH key, so Ansible can log in to the Google computer

Ansible reaches the Google computer through a Google-protected tunnel called **IAP**, and needs a key
that Google knows about. Create one (it won't overwrite an existing key; if asked, answer `n`):

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

Register it with Google:

```bash
gcloud compute os-login ssh-keys add --key-file ~/.ssh/id_ed25519.pub
```

Ask Google for your login name:

```bash
gcloud compute os-login describe-profile --format='value(posixAccounts[0].username)'
```

It looks like `yourname_gmail_com`. Put it on the `GCP_OSLOGIN_USER` line of your settings file:

```bash
nano ~/cloudbridge-go-live.env
```

---

## Part 7: Set up Cloudflare and your domain

**This is the part that costs real money.**

### 7.1 Get a domain

1. Create an account at <https://dash.cloudflare.com> and choose the **Free** plan.
2. The easiest route is to buy a domain through **Domain Registration** in Cloudflare's dashboard.
   A `.com` costs about US$10–15 a year, and the setup is automatic.
3. If you already own a domain elsewhere, click **Add a domain** in Cloudflare and keep your existing
   records (especially email). Then, on your registrar's site, change the nameservers to the two that
   Cloudflare shows you. This can take from minutes to a day.
4. Wait until the domain says **Active**.

### 7.2 Turn on Load Balancing

1. In the dashboard, open **Load Balancing** (under Traffic), then **Enable**.
2. It asks you to set up billing. **Before you confirm, read the price and what's included.**

> **Check this:** your setup asks Cloudflare to run health checks from **2 regions** (`SAS` and `SEAS`,
> near Mumbai). One Cloudflare pricing page I found through a search says the base price includes
> **1 region**, and more costs about US$10/month extra. I couldn't open that page, and the pages I could
> read don't say either way. So look at the billing screen. If 2 regions would cost extra, use the
> one-region change in Part 8.3.

### 7.3 Set up Zero Trust

This protects your cells' private admin addresses.

1. In the dashboard, open **Zero Trust**.
2. Choose a **team name** and write it down. Week 4 needs it.
3. Choose the **Free** plan. It asks for a card, but says you won't be charged on Free.

### 7.4 Copy two IDs

Open your domain's **Overview** page. On the right you'll find **Zone ID** and **Account ID**. These
aren't secrets. Put them, with your domain, into your settings file (the `DOMAIN` value has no `https://`
and no `www`, just `example.com`):

```bash
nano ~/cloudbridge-go-live.env
```

```bash
source ~/cloudbridge-go-live.env
```

### 7.5 Make a Cloudflare token

1. Click your profile (top right), **My Profile → API Tokens → Create Token → Custom token**.
2. Name it `cloudbridge` and add exactly these permissions:

| Scope | Permission | Level |
|---|---|---|
| Zone | Load Balancers | Edit |
| Zone | DNS | Edit |
| Zone | Zone Settings | Edit |
| Zone | SSL and Certificates | Edit |
| Account | Load Balancing: Monitors and Pools | Edit |
| Account | Access: Apps and Policies | Edit |
| Account | Access: Service Tokens | Edit |

3. Under Zone Resources, choose your domain only. Under Account Resources, choose your account.
4. Create it and keep the page open. It's shown only once.

You'll enter it in Part 9. **It isn't saved anywhere, so if you lose it, make a new one.**

---

## Part 8: Publish your settings to GitHub

Argo CD reads your app's settings from GitHub's `main` branch, not from your PC. So your domain must
reach `main` **before** the cells start.

### 8.1 Write the domain and IDs into the project

In your Linux terminal:

```bash
sed -i "s/^domain: cloudbridge\.example/domain: $DOMAIN/" gitops/global/values.yaml
```

```bash
sed -i "s/\"zone_id\": \"[0-9a-f]*\"/\"zone_id\": \"$CF_ZONE_ID\"/; s/\"account_id\": \"[0-9a-f]*\"/\"account_id\": \"$CF_ACCOUNT_ID\"/" infra/live/global/30-traffic/terraform.tfvars.json
```

### 8.2 Check nothing was missed

Both of these should print nothing:

```bash
grep -rn --exclude-dir=.terraform -E 'REPLACE-ME|"cb-tfstate-(aws|gcp)"|0{32}' infra
```

```bash
grep -n "cloudbridge.example" gitops/global/values.yaml
```

### 8.3 Only if 2 health-check regions cost extra (from Part 7.2)

Skip this unless you need it. It changes Cloudflare's checks to run from one region:

```bash
sed -i 's/check_regions   = \["SAS", "SEAS"\]/check_regions   = ["SAS"]/' infra/live/global/30-traffic/main.tf
```

### 8.4 Send it to GitHub

These files hold only names and IDs, which aren't secrets, so they're fine in a public repo. In your
**PowerShell window** (not Linux), run these one at a time. Look at the `git status` output first: it
should list only files under `infra/` and `gitops/global/`.

```powershell
git status
```

```powershell
git add infra gitops/global/values.yaml
```

```powershell
git commit -m "Set the real domain, cloud project and state buckets for go-live"
```

```powershell
git push -u origin go-live-values
```

```powershell
gh pr create --fill
```

Open the pull request link it prints, wait for the checks to turn green, then click **Merge**.
GitHub won't force you to wait, because `main` has no protection rules, so wait for them yourself.

Then bring your PC up to date:

```powershell
git switch main; git pull
```

> **Keep this repository public.** Argo CD in your cells downloads from GitHub without a password, so
> if the repo goes private, the cells can't get updates until credentials are added.

---

## Part 9: Go live, one step at a time

> **Why not `make budget-up`?** The older runbook uses that one command, and says you can read the plan
> before confirming. In fact it applies each plan **immediately, with no question**. These steps run the
> same things separately, so you can read the plan and see exactly where any problem starts.

Back in your Linux terminal, do your routine, then enter the Cloudflare token (paste, nothing shows,
press Enter):

```bash
source ~/.venvs/cloudbridge/bin/activate
```

```bash
source ~/cloudbridge-go-live.env
```

```bash
read -rs CLOUDFLARE_API_TOKEN && export CLOUDFLARE_API_TOKEN
```

Check the token works. You should see `"status":"active"`:

```bash
curl -s -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" https://api.cloudflare.com/client/v4/user/tokens/verify | jq -c .result
```

**Use this same terminal for all of Part 9**, since the token is only in this window. Part 9 takes
about an hour. If you do close it, repeat the three commands above.

### Step 1: Create the AWS computer

First, ask Terraform what it would do. Nothing is created yet.

```bash
make -C infra plan CLOUD=aws ENV=budget
```

Read the last lines. You want something like `Plan: N to add, 0 to change, 0 to destroy.` In the list
you should see one `t3.small` instance. If anything says `destroy`, stop and ask. If it looks right:

```bash
make -C infra apply CLOUD=aws ENV=budget
```

**Billing has begun**, from your credit. It should end with `Apply complete!`.

### Step 2: Create the Google computer

```bash
make -C infra plan CLOUD=gcp ENV=budget
```

Read it the same way, and look for one `e2-small` instance. Then:

```bash
make -C infra apply CLOUD=gcp ENV=budget
```

### Step 3: Create the security certificate

This asks Cloudflare for a certificate and stores it in both clouds, so traffic between Cloudflare and
your computers is encrypted. **This one applies with no question**, but it's small and safe.

```bash
make -C infra origin-tls
```

### Step 4: Set up both computers with Ansible (about 15–25 minutes)

Ansible logs in to each computer, hardens it, and installs k3s and Argo CD. Argo CD then installs your
app. At the end it keeps retrying a health check for up to 10 minutes, so long waits are normal there.

```bash
make -C infra configure
```

Near the end, you want to see `failed=0` and `unreachable=0` for both computers.

A brand-new AWS computer can take a few minutes to become reachable. If Ansible says `UNREACHABLE`
straight away, wait 5 minutes and run it again. Running it twice is safe.

**At this point both cells work, but the public can't reach them yet.**

### Step 5: Turn on Cloudflare

This creates the load balancer, the health checks and the protected admin addresses. **It also applies
with no question, and your site goes public at the end of it.**

```bash
make -C infra traffic
```

It should end with `Apply complete!`. The last lines include `allocator_client_secret = <sensitive>`,
which is meant to stay hidden.

---

## Part 10: Check that you're live

Give Cloudflare about 5 minutes first. A brand-new domain's certificate can take longer.

### Test 1: Open it in a browser

Run this to get your link, then open it:

```bash
echo "https://$CB_HOSTNAME/healthz/cell"
```

A plain response with no error page means the app is answering. **This app is an API with no website
yet**, so a plain response is what success looks like.

### Test 2: Both clouds are answering

This sends 40 requests and counts which cell answered each one:

```bash
for i in $(seq 1 40); do curl -s -o /dev/null -D - "https://$CB_HOSTNAME/healthz/cell" | grep -i '^x-cb-cell'; done | sort | uniq -c
```

You want both `cb-aws-budget` and `cb-gcp-budget`, with roughly 28 and 12. It won't be exact, since 40
requests is a small sample. **If you see both, your multi-cloud app is live. Congratulations!**

### Test 3: The admin address is locked

This should print a line containing `401`:

```bash
curl -sI "https://admin-aws.$DOMAIN/admin/leases/report" | head -1
```

### Test 4: The computers can't be reached directly

Get the Google computer's public address (`EXTERNAL_IP`):

```bash
gcloud compute instances list
```

Replace `THE-IP` with it and run this. It should wait 10 seconds, then fail with a timeout. That's the
correct result: only Cloudflare is allowed in.

```bash
curl -m 10 -k https://THE-IP/healthz/cell
```

### What won't work yet

Buying stock across the two clouds needs the lease allocator from Week 4, so placing a real order may be
refused. Dashboards and canary analysis arrive in Weeks 5–7. That's expected at this stage.

---

## Part 11: When something goes wrong

Stop, and copy the full error into Claude, **after removing any keys or tokens**. Common cases:

| What you see | What it means | What to do |
|---|---|---|
| `command not found: terraform` or `ansible-playbook` | You skipped your routine | Run the two `source` lines from Part 2 |
| Empty values, or `gs://` with no name | Settings file not loaded or incomplete | `source ~/cloudbridge-go-live.env`, and check for `FILL-IN` with `grep FILL-IN ~/cloudbridge-go-live.env` |
| `billing account ... disabled` or `not enabled` | Google project isn't linked to the trial | In Google's console, open **Billing** and link your project |
| `Quota exceeded` on Google | The trial limits resources, and it can't request more | Check nothing is left over from Part 4, then ask for help |
| `Error acquiring the state lock` | Another Terraform run is active, or one crashed | Wait a few minutes. Don't force anything without asking |
| Cloudflare error mentioning `check_regions` or a plan limit | The plan may not allow 2 regions | Do Part 8.3, send it through a pull request, then repeat `make -C infra traffic` |
| `403` or `Unauthorized` from Cloudflare | Token permission missing | Compare it against the table in Part 7.5 |
| Cloudflare provider download fails | A network block seen here in October | Follow Part 5 step 2 of `docs/runbooks/week-2-go-live.md` |
| `Permission denied (publickey)` on the Google computer | Part 6.2 wasn't finished | Repeat Part 6.2, then re-run `make -C infra configure` |
| `UNREACHABLE` on AWS | The computer is still starting | Wait 5 minutes and re-run `make -C infra configure` |
| Ansible health check keeps retrying, then fails | The app didn't start in time, often memory or a slow first download | See "Look inside a cell" below |
| Browser shows Cloudflare **521** or **522** | Cloudflare can't reach a cell | Check the computers are running and the app has started |
| Browser shows Cloudflare **525** or **526** | Certificate problem | Check `make -C infra origin-tls` and `configure` both succeeded |
| Only one cell appears in Test 2 | The other cell is failing health checks | Open **Load Balancing** in Cloudflare to see pool health, then look inside that cell |

### Look inside a cell

These commands are read-only. First find the computers:

```bash
gcloud compute instances list
```

```bash
aws ec2 describe-instances --region ap-south-1 --filters Name=tag:cb-ansible-role,Values=k3s_server Name=instance-state-name,Values=running --query 'Reservations[].Instances[].[InstanceId,PublicIpAddress]' --output text
```

Log in, replacing `THE-NAME` with the Google computer's name, or `THE-ID` with the AWS ID (`i-...`):

```bash
gcloud compute ssh THE-NAME --zone asia-south1-a --tunnel-through-iap
```

```bash
aws ssm start-session --region ap-south-1 --target THE-ID
```

Once inside, these show how Argo CD and your app are doing. You want `Synced`, `Healthy` and `Running`.
The first start can take 5–10 minutes. Type `exit` to leave.

```bash
sudo k3s kubectl -n argocd get applications
```

```bash
sudo k3s kubectl -n cb-app get pods
```

---

## Part 12: Stop paying when you don't need it

### Shut it all down

Stopping a computer isn't enough, because disks and addresses keep costing money. To remove it all:

```bash
make -C infra budget-down
```

It asks you to type `yes` three times: Cloudflare, Google, AWS. **The demo database lives on those
computers, so its data is deleted for good.** Run through Part 9 again whenever you want it back. The
buckets, secrets and certificate stay, and cost only pennies.

### Cancel what `budget-down` doesn't cover

| Item | How to stop it |
|---|---|
| Cloudflare Load Balancing (US$5+/month) | It may keep billing after `budget-down`. Check **Billing → Subscriptions** in Cloudflare and cancel it if you're stopping for a while |
| Domain | Renews yearly. Turn off auto-renew if you no longer want it |

### Dates to put in your calendar

- **Two weeks before Google's day 90:** decide whether to upgrade to a paid account or shut down.
- **Two weeks before AWS's month 6:** the same decision.
- **Why it matters:** when an offer ends, your computers stop, and the project's records no longer match
  what's really there. Run `make -C infra budget-down` *before* that happens.

### Check your spending weekly

For the first month, spend two minutes a week looking at the credit left in Google's **Billing** page,
AWS's **Free Tier** page and Cloudflare's **Billing** page.

### Using the local twin again

The twin's certificates were made for the old placeholder domain. Before using it again, clear its
local data, then start it. This deletes only the twin's own files and cached images, not your cloud cells:

```bash
bash tools/dev/twin.sh purge
```

```bash
bash tools/dev/twin.sh up
```

---

## Words you'll see

| Word | Meaning |
|---|---|
| **Region** | A location of a cloud's data centres. `ap-south-1` (AWS) and `asia-south1` (Google) are both Mumbai |
| **Instance / VM** | A rented computer |
| **Bucket** | A rented folder for files |
| **Credit** | Free money from a cloud company, used up as you run things |
| **Origin** | Your computer that Cloudflare forwards visitors to |
| **Plan / apply** | Terraform's preview / actually doing it |
| **State** | Terraform's record of what it has created |
| **Destroy** | Delete the rented things, permanently |
| **Pool** | Cloudflare's name for one group of origins. You have one per cloud |
| **Health check / monitor** | Cloudflare testing `/healthz/cell` regularly to see if a cell is alive |
| **Token / key** | A password for a program. Keep it secret |
| **Pull request (PR)** | A proposed change on GitHub, reviewed and then merged into `main` |

---

## Where this guide differs from the older runbook

`docs/runbooks/week-2-go-live.md` has more technical background and its sources. Where they differ,
follow this guide:

| Older runbook | This guide | Why |
|---|---|---|
| `make budget-up`, and "read the plans before you confirm" | Separate steps | The command applies with no confirmation |
| No SSH key step | Part 6.2 | Ansible needs a key registered with Google, and nothing creates one |
| IAM user with no permissions named | `AdministratorAccess` | A beginner needs to know which to pick |
| Bucket rename across the whole repo, run exactly once | Only inside `infra/`, safe to run twice | It no longer changes docs and skills, or breaks if repeated |
| "`main` is protected" | It has no protection rules | Checked on 2 Nov 2026 |
| Provider mirror required | Only if the download fails | The block was gone when last checked, on 1 Nov 2026 |

Sources checked on 2 Nov 2026: [Google Cloud free trial](https://docs.cloud.google.com/free/docs/free-cloud-features),
[AWS Free Tier plans](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-plans.html),
[Cloudflare plans](https://www.cloudflare.com/plans/application-services/),
[Enable Load Balancing](https://developers.cloudflare.com/load-balancing/get-started/enable-load-balancing/).
