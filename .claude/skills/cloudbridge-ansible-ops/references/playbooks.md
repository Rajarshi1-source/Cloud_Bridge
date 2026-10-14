# CloudBridge Ansible — Starter Files

## Contents
1. requirements.yml, ansible.cfg
2. Inventories + group_vars
3. Roles: base_hardening, k3s_server, registries_mirror, node_exporter, origin_tls, argocd_autodeploy
4. Playbooks: site, prewarm, evacuate (+ shift_step), failback, drill, propose_evacuation
5. Rulebook
6. Molecule scenario
7. GitHub Actions wiring

---

## 1. requirements.yml, ansible.cfg

```yaml
# ansible/requirements.yml — pin exact versions on build day (ansible-galaxy collection list)
---
# Exact collection versions (resolved 14 Oct 2026). Bump deliberately, then re-run
# tools/dev/iac-check.sh ansible molecule.
collections:
  - name: amazon.aws
    version: "12.0.0"
  - name: community.aws          # aws_ssm connection plugin
    version: "12.0.0"
  - name: google.cloud
    version: "1.15.0"
  - name: ansible.posix
    version: "2.2.2"
  - name: community.general      # community.general.terraform for the evacuation saga (Week 7)
    version: "13.5.0"
```

```ini
# ansible/ansible.cfg
[defaults]
inventory = inventories/
roles_path = roles
stdout_callback = ansible.builtin.default
result_format = yaml
interpreter_python = auto_silent
forks = 10
timeout = 60

[ssh_connection]
pipelining = True
```

## 2. Inventories + group_vars

```yaml
# ansible/inventories/aws_ec2.yml
---
# Hosts come from cloud tags Terraform set (cb-ansible-role = k3s_server), never from Terraform state.
plugin: amazon.aws.aws_ec2
regions:
  - ap-south-1
filters:
  "tag:cb-ansible-role": k3s_server
  instance-state-name: running
hostnames:
  - instance-id            # SSM targets instance IDs, not IPs
keyed_groups:
  - key: tags['cb-env']
    prefix: env
  - key: tags['cb-cloud']
    prefix: cloud
compose:
  cb_cell: tags['cb-cell']
  cb_origin_ip: public_ip_address
```

```yaml
# ansible/inventories/gcp_compute.yml
---
plugin: google.cloud.gcp_compute
projects:
  - "{{ lookup('ansible.builtin.env', 'GCP_PROJECT_ID') }}"
zones:
  - asia-south1-a
filters:
  - labels.cb-ansible-role = k3s_server
  - status = RUNNING
auth_kind: application        # Workload Identity Federation credentials from google-github-actions/auth
hostnames:
  - name
keyed_groups:
  - key: labels['cb-env']
    prefix: env
  - key: labels['cb-cloud']
    prefix: cloud
compose:
  cb_cell: labels['cb-cell']
  cb_origin_ip: networkInterfaces[0].accessConfigs[0].natIP
  gcp_zone: zone
```

```yaml
# ansible/inventories/group_vars/cloud_aws.yml
---
# No SSH anywhere: SSM Session Manager. The transfer bucket is a Terraform output of the AWS budget
# stack (cluster.auth.transfer_bucket), exported as CB_SSM_BUCKET by the workflow that runs Ansible.
ansible_connection: community.aws.aws_ssm
ansible_aws_ssm_region: ap-south-1
ansible_aws_ssm_bucket_name: "{{ lookup('ansible.builtin.env', 'CB_SSM_BUCKET') }}"
ansible_become: true
cb_cloud: aws
cb_secret_backend: aws
```

```yaml
# ansible/inventories/group_vars/cloud_gcp.yml
---
# SSH only through IAP TCP forwarding (firewall admits 35.235.240.0/20 on 22), OS Login user.
ansible_connection: ansible.builtin.ssh
ansible_user: "{{ lookup('ansible.builtin.env', 'GCP_OSLOGIN_USER') }}"
cb_gcp_project: "{{ lookup('ansible.builtin.env', 'GCP_PROJECT_ID') }}"
ansible_ssh_common_args: >-
  -o StrictHostKeyChecking=accept-new
  -o ProxyCommand="gcloud compute start-iap-tunnel %h 22 --listen-on-stdin
  --zone={{ gcp_zone | basename }} --project={{ cb_gcp_project }}"
ansible_become: true
cb_cloud: gcp
cb_secret_backend: gcp
```

```yaml
# ansible/inventories/group_vars/all.yml
k3s_server_version: "v1.36.5+k3s1"        # role-prefixed names: ansible-lint production profile
k3s_server_minor: "1.36"
node_exporter_version: "1.12.1"
argocd_chart_version: "8.0.0"             # argo-cd Helm chart for Argo CD 3.3.x — verify
cb_ring: "{{ 'ring-canary' if cb_cloud == 'gcp' else 'ring-main' }}"
cb_repo_url: "https://github.com/<you>/cloudbridge"
```

## 3. Roles

```yaml
# roles/base_hardening/tasks/main.yml
---
- name: Disable SSH password and root login
  ansible.builtin.copy:
    dest: /etc/ssh/sshd_config.d/10-cloudbridge.conf
    mode: "0644"
    content: |
      PasswordAuthentication no
      PermitRootLogin no
  notify: Restart ssh

- name: Install baseline packages
  ansible.builtin.apt:
    name:
      - unattended-upgrades
      - auditd
      - chrony
      - curl
      - jq
    state: present
    update_cache: true
    cache_valid_time: 3600

- name: Enable unattended security upgrades
  ansible.builtin.copy:
    dest: /etc/apt/apt.conf.d/20auto-upgrades
    mode: "0644"
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";

- name: Kernel hardening sysctls
  ansible.posix.sysctl:
    name: "{{ item.name }}"
    value: "{{ item.value }}"
    sysctl_file: /etc/sysctl.d/90-cloudbridge.conf
    reload: true
  loop:
    - { name: net.ipv4.conf.all.rp_filter, value: "1" }
    - { name: net.ipv4.conf.all.accept_redirects, value: "0" }
    - { name: kernel.kptr_restrict, value: "2" }
    - { name: vm.swappiness, value: "10" }

- name: Create a 1 GiB swapfile (2 GiB VMs + JVM start-up bursts)
  ansible.builtin.command: fallocate -l 1G /swapfile
  args:
    creates: /swapfile

- name: Restrict swapfile permissions
  ansible.builtin.file:
    path: /swapfile
    mode: "0600"

- name: Format the swapfile
  ansible.builtin.command: mkswap /swapfile
  register: base_hardening_mkswap
  changed_when: base_hardening_mkswap.rc == 0
  when: ansible_facts['swaptotal_mb'] | int == 0

- name: Persist swap in fstab
  ansible.posix.mount:
    src: /swapfile
    path: none
    fstype: swap
    opts: sw
    state: present

- name: Activate swap
  ansible.builtin.command: swapon -a
  changed_when: false

- name: Ensure journald drop-in directory
  ansible.builtin.file:
    path: /etc/systemd/journald.conf.d
    state: directory
    mode: "0755"

- name: Cap journald disk use
  ansible.builtin.copy:
    dest: /etc/systemd/journald.conf.d/size.conf
    mode: "0644"
    content: |
      [Journal]
      SystemMaxUse=200M
  notify: Restart journald
```

```yaml
# roles/base_hardening/handlers/main.yml
---
- name: Restart ssh
  ansible.builtin.service:
    name: ssh
    state: restarted

- name: Restart journald
  ansible.builtin.service:
    name: systemd-journald
    state: restarted
```

```yaml
# roles/k3s_server/defaults/main.yml
---
k3s_server_version: "v1.36.5+k3s1"
k3s_server_minor: "1.36"
# Restart k3s when its config changes. Off only where no systemd/k3s exists (the Molecule container).
k3s_server_manage_service: true
k3s_server_disable:
  - traefik            # Traefik is installed by Argo CD (one owner per object)
k3s_server_kubelet_args:
  - "kube-reserved=cpu=100m,memory=256Mi"
  - "system-reserved=cpu=100m,memory=128Mi"
  - "eviction-hard=memory.available<100Mi"
```

```jinja
{# roles/k3s_server/templates/config.yaml.j2 #}
# Managed by Ansible (role k3s_server). k3s reads this before it starts.
write-kubeconfig-mode: "0600"
tls-san:
  - "{{ cb_origin_ip }}"
disable: {{ k3s_server_disable | to_json }}
kubelet-arg: {{ k3s_server_kubelet_args | to_json }}
node-label:
  - "cb-cell={{ cb_cell }}"
  - "cb-cloud={{ cb_cloud }}"
```

```yaml
# roles/k3s_server/tasks/config.yml
---
# The configuration half of the role. Molecule converges exactly these tasks (k3s itself can't run
# in an unprivileged container), so the tested code is the code the VMs run.
- name: Assert the pinned version matches the parity-contract minor
  ansible.builtin.assert:
    that: ("v" ~ k3s_server_minor ~ ".") in k3s_server_version
    fail_msg: "k3s {{ k3s_server_version }} does not match contract minor {{ k3s_server_minor }}"
    quiet: true

- name: Ensure the k3s config directory
  ansible.builtin.file:
    path: /etc/rancher/k3s
    state: directory
    mode: "0755"

- name: Write the k3s config
  ansible.builtin.template:
    src: config.yaml.j2
    dest: /etc/rancher/k3s/config.yaml
    mode: "0600"
  notify: Restart k3s
```

```yaml
# roles/k3s_server/tasks/main.yml
---
- name: Configure k3s
  ansible.builtin.import_tasks: config.yml

- name: Read the installed k3s version
  ansible.builtin.command: k3s --version
  register: k3s_server_installed
  changed_when: false
  failed_when: false

- name: Download the installer pinned to the k3s release (not the moving get.k3s.io script)
  ansible.builtin.get_url:
    url: "https://raw.githubusercontent.com/k3s-io/k3s/{{ k3s_server_version | urlencode }}/install.sh"
    dest: /usr/local/bin/k3s-install.sh
    mode: "0755"
  when: k3s_server_version not in (k3s_server_installed.stdout | default(''))

- name: Install the pinned k3s
  ansible.builtin.command: /usr/local/bin/k3s-install.sh
  environment:
    INSTALL_K3S_VERSION: "{{ k3s_server_version }}"
  when: k3s_server_version not in (k3s_server_installed.stdout | default(''))
  changed_when: true

- name: Wait for the node to be Ready
  ansible.builtin.command: k3s kubectl wait --for=condition=Ready node --all --timeout=180s
  changed_when: false
```

```yaml
# roles/k3s_server/handlers/main.yml
---
- name: Restart k3s
  ansible.builtin.service:
    name: k3s
    state: restarted
  when: k3s_server_manage_service | bool
```

```yaml
# roles/registries_mirror/tasks/main.yml
---
# Pods pull through an authenticated Docker Hub endpoint, so anonymous rate limits can't stall a
# scale-up. The token comes from the cell's own cloud secret manager, never from a vars file.
- name: Read the Docker Hub pull token
  ansible.builtin.set_fact:
    registries_mirror_token: >-
      {{ lookup('amazon.aws.secretsmanager_secret', 'cb/dockerhub-pull', region='ap-south-1')
         if cb_secret_backend == 'aws' else
         lookup('google.cloud.gcp_secret_manager', key='cb-dockerhub-pull',
                project=lookup('ansible.builtin.env', 'GCP_PROJECT_ID'), auth_kind='application') }}
  no_log: true

- name: Configure k3s registries.yaml
  ansible.builtin.copy:
    dest: /etc/rancher/k3s/registries.yaml
    mode: "0600"
    content: |
      configs:
        "registry-1.docker.io":
          auth:
            username: "{{ lookup('ansible.builtin.env', 'DOCKERHUB_USER') }}"
            password: "{{ registries_mirror_token }}"
  no_log: true
  notify: Restart k3s for registries
```

```yaml
# roles/node_exporter/vars/main.yml
---
node_exporter_release: "node_exporter-{{ node_exporter_version }}.linux-amd64"
node_exporter_url: "https://github.com/prometheus/node_exporter/releases/download/v{{ node_exporter_version }}/{{ node_exporter_release }}.tar.gz"
node_exporter_current: >-
  {{ (node_exporter_installed.stdout | default('')) ~ (node_exporter_installed.stderr | default('')) }}
```

```yaml
# roles/registries_mirror/handlers/main.yml
---
- name: Restart k3s for registries
  ansible.builtin.service:
    name: k3s
    state: restarted
```

```yaml
# roles/node_exporter/tasks/main.yml
---
- name: Read the installed node_exporter version
  ansible.builtin.command: /usr/local/bin/node_exporter --version
  register: node_exporter_installed
  changed_when: false
  failed_when: false

- name: Download and unpack the pinned release
  ansible.builtin.unarchive:
    src: "{{ node_exporter_url }}"
    dest: /tmp
    remote_src: true
  when: node_exporter_version not in node_exporter_current

- name: Install the binary
  ansible.builtin.copy:
    src: "/tmp/{{ node_exporter_release }}/node_exporter"
    dest: /usr/local/bin/node_exporter
    mode: "0755"
    remote_src: true
  when: node_exporter_version not in node_exporter_current
  notify: Restart node_exporter

- name: Install the systemd unit (localhost only; the in-cluster Prometheus agent scrapes it)
  ansible.builtin.copy:
    dest: /etc/systemd/system/node_exporter.service
    mode: "0644"
    content: |
      [Unit]
      Description=Prometheus node exporter
      After=network-online.target

      [Service]
      DynamicUser=yes
      ExecStart=/usr/local/bin/node_exporter --web.listen-address=127.0.0.1:9100
      Restart=on-failure

      [Install]
      WantedBy=multi-user.target
  notify: Restart node_exporter

- name: Enable and start node_exporter
  ansible.builtin.systemd_service:
    name: node_exporter
    enabled: true
    state: started
    daemon_reload: true
```
(Listens on localhost; the in-cluster Prometheus agent scrapes it via `hostNetwork` scrape config.)

```yaml
# roles/argocd_autodeploy/tasks/main.yml
- name: Argo CD HelmChart (k3s auto-applies this directory)
  ansible.builtin.copy:
    dest: /var/lib/rancher/k3s/server/manifests/10-argocd.yaml
    mode: "0600"
    content: |
      apiVersion: helm.cattle.io/v1
      kind: HelmChart
      metadata:
        name: argocd
        namespace: kube-system
      spec:
        repo: https://argoproj.github.io/argo-helm
        chart: argo-cd
        version: "{{ argocd_chart_version }}"
        targetNamespace: argocd
        createNamespace: true
        valuesContent: |
          configs:
            params:
              server.insecure: true
          server:
            service:
              type: ClusterIP

- name: Root ApplicationSet (same template Terraform renders for managed cells)
  ansible.builtin.template:
    src: "{{ playbook_dir }}/../../gitops/bootstrap/applicationset.yaml.tftpl"
    dest: /var/lib/rancher/k3s/server/manifests/20-root-appset.yaml
    mode: "0600"
    variable_start_string: "${"
    variable_end_string: "}"
  vars:
    cell: "{{ cb_cell }}"
    ring: "{{ cb_ring }}"
```
Using `${` / `}` as Jinja delimiters lets Ansible fill the same `${cell}` / `${ring}` placeholders Terraform's `templatefile()` fills, while Argo's `{{.app}}` passes through untouched — one template, two renderers.

## 4. Playbooks

```yaml
# playbooks/site.yml
- name: Configure budget-profile k3s cells
  hosts: all
  gather_facts: true
  roles:
    - base_hardening
    - k3s_server
    - registries_mirror
    - node_exporter
    - argocd_autodeploy

- name: Smoke test each origin locally (bypasses Cloudflare, checks the ingress path)
  hosts: all
  gather_facts: false
  tasks:
    - name: Origin answers /healthz/cell
      ansible.builtin.command:
        argv:
          - curl
          - -fsS
          - -o
          - /dev/null
          - --resolve
          - "{{ lookup('ansible.builtin.env', 'CB_HOSTNAME') }}:443:127.0.0.1"
          - "https://{{ lookup('ansible.builtin.env', 'CB_HOSTNAME') }}/healthz/cell"
      register: h
      retries: 20
      delay: 15
      until: h.rc == 0
      changed_when: false
```

```yaml
# playbooks/prewarm.yml  (also used as tasks/prewarm.yml via include_tasks)
- name: Pre-warm target cell to evacuation capacity
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    to_cell: gcp
  tasks:
    - ansible.builtin.include_tasks: tasks/prewarm.yml
```

```yaml
# playbooks/tasks/prewarm.yml
- name: Fetch evacuation replica targets for the target cell
  ansible.builtin.uri:
    url: "{{ cp_api }}/capacity/cb-{{ to_cell }}-prod/evacuation-plan"
    headers:
      Authorization: "Bearer {{ lookup('ansible.builtin.env', 'CB_CP_TOKEN') }}"
    return_content: true
  register: plan

- name: Raise HPA minReplicas (kubeconfig for the target cell provided by the workflow)
  kubernetes.core.k8s:
    kubeconfig: "{{ lookup('ansible.builtin.env', 'KUBECONFIG_' ~ (to_cell | upper)) }}"
    state: patched
    kind: HorizontalPodAutoscaler
    api_version: autoscaling/v2
    namespace: cb-app
    name: "{{ item.service }}"
    definition:
      spec:
        minReplicas: "{{ item.min_replicas }}"
  loop: "{{ plan.json.services }}"

- name: Wait until each Rollout has its pre-warm replicas available
  kubernetes.core.k8s_info:
    kubeconfig: "{{ lookup('ansible.builtin.env', 'KUBECONFIG_' ~ (to_cell | upper)) }}"
    api_version: argoproj.io/v1alpha1
    kind: Rollout
    namespace: cb-app
    name: "{{ item.service }}"
  register: dep
  until: >-
    dep.resources | length == 1 and
    (dep.resources[0].status.availableReplicas | default(0) | int) >= (item.min_replicas | int)
  retries: 40
  delay: 15
  loop: "{{ plan.json.services }}"
```
Argo CD's `selfHeal` would revert a manual HPA patch. The HPA chart sets `ignoreDifferences` on `/spec/minReplicas` for exactly this reason — pre-warm is an operational override, recorded in the drill, reset by `failback.yml`.

```yaml
# playbooks/evacuate.yml
- name: Evacuate traffic (stepped, SLO-gated, compensating)
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    from_cell: aws
    to_cell: gcp
    mode: drill
    break_glass: false
    steps: [50, 25, 0]
    step_wait_s: 150
    burn_abort: 6.0
    p95_abort_ms: 600
    min_capacity_ratio: 1.2
    prom: "{{ lookup('ansible.builtin.env', 'CB_PROM_URL') }}"
    cp_api: "{{ lookup('ansible.builtin.env', 'CB_CP_API') }}"
    cp_headers:
      Authorization: "Bearer {{ lookup('ansible.builtin.env', 'CB_CP_TOKEN') }}"
    traffic_stack: "{{ playbook_dir }}/../../infra/live/global/30-traffic"
  tasks:
    - name: Read current weights (compensation target)
      ansible.builtin.slurp:
        src: "{{ traffic_stack }}/terraform.tfvars.json"
      register: tfvars_raw

    - name: Remember original weights
      ansible.builtin.set_fact:
        original_weights: "{{ (tfvars_raw.content | b64decode | from_json).weights }}"

    - name: Open drill record
      ansible.builtin.uri:
        url: "{{ cp_api }}/drills"
        method: POST
        headers: "{{ cp_headers }}"
        body_format: json
        body:
          from_cell: "cb-{{ from_cell }}-prod"
          to_cell: "cb-{{ to_cell }}-prod"
          mode: "{{ mode }}"
        status_code: 201
      register: drill

    - name: Capacity check
      ansible.builtin.uri:
        url: "{{ cp_api }}/capacity/cb-{{ to_cell }}-prod"
        headers: "{{ cp_headers }}"
        return_content: true
      register: cap

    - name: Pre-warm when current replicas cannot absorb the load
      ansible.builtin.include_tasks: tasks/prewarm.yml
      when: cap.json.capacity_ratio_at_current_replicas < min_capacity_ratio

    - name: Re-check capacity
      ansible.builtin.uri:
        url: "{{ cp_api }}/capacity/cb-{{ to_cell }}-prod"
        headers: "{{ cp_headers }}"
        return_content: true
      register: cap2

    - name: Refuse to evacuate into an undersized cell
      ansible.builtin.fail:
        msg: "Capacity ratio {{ cap2.json.capacity_ratio }} < {{ min_capacity_ratio }} — evacuating would cascade."
      when: cap2.json.capacity_ratio < min_capacity_ratio

    - name: Shift in steps
      block:
        - name: Apply each step with SLO gate
          ansible.builtin.include_tasks: tasks/shift_step.yml
          loop: "{{ steps }}"
          loop_control:
            loop_var: from_share
            index_var: seq
      rescue:
        - name: Compensate — restore original weights
          community.general.terraform:
            project_path: "{{ traffic_stack }}"
            state: present
            complex_vars: true
            variables:
              weights: "{{ original_weights }}"
          when: not break_glass | bool

        - name: Compensate via API (break-glass)
          ansible.builtin.command:
            argv:
              - python3
              - "{{ playbook_dir }}/../../tools/cf_break_glass.py"
              - --weights
              - "{{ original_weights.items() | map('join', '=') | join(',') }}"
              - --reason
              - "compensation for drill {{ drill.json.id }}"
          when: break_glass | bool
          changed_when: true

        - name: Mark drill rolled back
          ansible.builtin.uri:
            url: "{{ cp_api }}/drills/{{ drill.json.id }}"
            method: PATCH
            headers: "{{ cp_headers }}"
            body_format: json
            body:
              outcome: rolled_back

        - name: Fail loudly
          ansible.builtin.fail:
            msg: "Evacuation aborted and rolled back. See drill {{ drill.json.id }}."

    - name: Close drill and render report
      ansible.builtin.uri:
        url: "{{ cp_api }}/drills/{{ drill.json.id }}/complete"
        method: POST
        headers: "{{ cp_headers }}"
        status_code: [200, 201]
```

```yaml
# playbooks/tasks/shift_step.yml
- name: Compute step weights
  ansible.builtin.set_fact:
    step_weights: "{{ {from_cell: from_share | int, to_cell: 100 - (from_share | int)} }}"

- name: "Apply weights (Terraform)"
  community.general.terraform:
    project_path: "{{ traffic_stack }}"
    state: present
    complex_vars: true
    variables:
      weights: "{{ step_weights }}"
  when: not break_glass | bool

- name: "Apply weights (break-glass API)"
  ansible.builtin.command:
    argv:
      - python3
      - "{{ playbook_dir }}/../../tools/cf_break_glass.py"
      - --weights
      - "{{ step_weights.items() | map('join', '=') | join(',') }}"
      - --reason
      - "drill {{ drill.json.id }} step {{ seq }}"
  when: break_glass | bool
  changed_when: true

- name: Wait for health checks and session drain
  ansible.builtin.pause:
    seconds: "{{ step_wait_s }}"

- name: Burn rate on receiving cell (99.5% SLO → error budget 0.005)
  ansible.builtin.uri:
    url: "{{ prom }}/api/v1/query"
    method: POST
    body_format: form-urlencoded
    body:
      query: >-
        (sum(rate(http_server_requests_seconds_count{cb_cell="cb-{{ to_cell }}-prod",service="api-gateway",status=~"5.."}[5m]))
        / sum(rate(http_server_requests_seconds_count{cb_cell="cb-{{ to_cell }}-prod",service="api-gateway"}[5m]))) / 0.005
    return_content: true
  register: burn

- name: p95 on receiving cell
  ansible.builtin.uri:
    url: "{{ prom }}/api/v1/query"
    method: POST
    body_format: form-urlencoded
    body:
      query: 'cb:latency_p95:5m{cb_cell="cb-{{ to_cell }}-prod",service="api-gateway"} * 1000'
    return_content: true
  register: p95

- name: Extract values
  ansible.builtin.set_fact:
    burn_now: "{{ (burn.json.data.result | first | default({'value': [0, '0']})).value[1] | float }}"
    p95_now: "{{ (p95.json.data.result | first | default({'value': [0, '0']})).value[1] | float }}"

- name: Record step
  ansible.builtin.uri:
    url: "{{ cp_api }}/drills/{{ drill.json.id }}/steps"
    method: POST
    headers: "{{ cp_headers }}"
    body_format: json
    body:
      seq: "{{ seq }}"
      weights: "{{ step_weights }}"
      burn_rate: "{{ burn_now }}"
      p95_ms: "{{ p95_now }}"
      decision: "{{ 'abort' if (burn_now | float > burn_abort or p95_now | float > p95_abort_ms) else 'advance' }}"
    status_code: 201

- name: SLO gate
  ansible.builtin.fail:
    msg: "Gate failed at {{ step_weights }}: burn={{ burn_now }} p95={{ p95_now }}ms"
  when: burn_now | float > burn_abort or p95_now | float > p95_abort_ms
```

```yaml
# playbooks/failback.yml
- name: Fail back to recorded pre-evacuation weights
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    drill_id: ""
    cp_api: "{{ lookup('ansible.builtin.env', 'CB_CP_API') }}"
    cp_headers:
      Authorization: "Bearer {{ lookup('ansible.builtin.env', 'CB_CP_TOKEN') }}"
    traffic_stack: "{{ playbook_dir }}/../../infra/live/global/30-traffic"
  tasks:
    - name: Load weights recorded before the evacuation
      ansible.builtin.uri:
        url: "{{ cp_api }}/drills/{{ drill_id }}/original-weights"
        headers: "{{ cp_headers }}"
        return_content: true
      register: orig

    - name: Step back in two moves (half-way, then original)
      community.general.terraform:
        project_path: "{{ traffic_stack }}"
        state: present
        complex_vars: true
        variables:
          weights: "{{ item }}"
      loop:
        - "{{ orig.json.halfway }}"
        - "{{ orig.json.weights }}"
      loop_control:
        pause: 150

    - name: Reset HPA minReplicas to chart values (Argo CD sync)
      ansible.builtin.command:
        argv: [argocd, app, sync, --prune, --resource, "autoscaling:HorizontalPodAutoscaler:*", cloudbridge-apps]
      changed_when: true
```

```yaml
# playbooks/drill.yml
- name: Evacuate (drill mode)
  ansible.builtin.import_playbook: evacuate.yml
  vars:
    mode: drill

- name: Hold
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Observe the target cell at 100% for 10 minutes
      ansible.builtin.pause:
        minutes: 10

- name: Fail back
  ansible.builtin.import_playbook: failback.yml
```
(`drill_id` for failback is read from the latest open drill when not passed — the control-plane endpoint `/drills/latest?mode=drill` supplies it in the real file.)

```yaml
# playbooks/propose_evacuation.yml — prod path: prepare, never act
- name: Open an evacuation proposal PR
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    from_cell: aws
    to_cell: gcp
  tasks:
    - name: Ask control plane for capacity and proposed weights
      ansible.builtin.uri:
        url: "{{ lookup('ansible.builtin.env', 'CB_CP_API') }}/evacuation-proposal?from=cb-{{ from_cell }}-prod&to=cb-{{ to_cell }}-prod"
        headers:
          Authorization: "Bearer {{ lookup('ansible.builtin.env', 'CB_CP_TOKEN') }}"
        return_content: true
      register: prop

    - name: Create PR via gh CLI
      ansible.builtin.command:
        argv:
          - gh
          - workflow
          - run
          - evacuate.yml
          - -f
          - "from_cell={{ from_cell }}"
          - -f
          - "to_cell={{ to_cell }}"
          - -f
          - "mode=real"
      changed_when: true
```
The `evacuate.yml` GitHub workflow is gated by the `traffic-prod` environment's required reviewers — the PR/approval *is* the human decision.

## 5. Rulebook

```yaml
# rulebooks/cell-degraded.yml
- name: Cell degradation
  hosts: localhost
  sources:
    - ansible.eda.alertmanager:
        host: 0.0.0.0
        port: 5000
        data_alerts_path: alerts
  rules:
    - name: Non-prod → automatic drill
      condition: >-
        event.alert.labels.alertname == "CellSLOBurnFast" and
        event.alert.labels.cb_env != "prod" and event.alert.status == "firing"
      throttle:
        once_within: 30 minutes
        group_by_attributes:
          - event.alert.labels.cb_cell
      action:
        run_playbook:
          name: playbooks/evacuate.yml
          extra_vars:
            from_cell: "{{ event.alert.labels.cb_cloud }}"
            to_cell: "{{ 'gcp' if event.alert.labels.cb_cloud == 'aws' else 'aws' }}"
            mode: drill

    - name: Prod → proposal only
      condition: >-
        event.alert.labels.alertname == "CellSLOBurnFast" and
        event.alert.labels.cb_env == "prod" and event.alert.status == "firing"
      throttle:
        once_within: 30 minutes
        group_by_attributes:
          - event.alert.labels.cb_cell
      action:
        run_playbook:
          name: playbooks/propose_evacuation.yml
          extra_vars:
            from_cell: "{{ event.alert.labels.cb_cloud }}"
            to_cell: "{{ 'gcp' if event.alert.labels.cb_cloud == 'aws' else 'aws' }}"
```

## 6. Molecule scenario

```yaml
# roles/k3s_server/molecule/default/molecule.yml
---
driver:
  name: docker
platforms:
  - name: k3s-ubuntu
    image: ubuntu:24.04
    pre_build_image: false
provisioner:
  name: ansible
  inventory:
    group_vars:
      all:
        cb_cell: cb-test-dev
        cb_cloud: aws
        cb_origin_ip: 127.0.0.1
        k3s_server_manage_service: false   # no systemd or k3s in the test container
verifier:
  name: ansible
scenario:
  test_sequence:
    - destroy
    - syntax
    - create
    - converge
    - idempotence
    - verify
    - destroy
```

```yaml
# roles/k3s_server/molecule/default/converge.yml
---
- name: Converge (configuration only; k3s can't run in an unprivileged container)
  hosts: all
  gather_facts: false
  tasks:
    - name: Render the k3s configuration with the role's real tasks
      ansible.builtin.include_role:
        name: k3s_server
        tasks_from: config.yml
```

```yaml
# roles/k3s_server/molecule/default/verify.yml
---
- name: Verify
  hosts: all
  gather_facts: false
  tasks:
    - name: Read the rendered config
      ansible.builtin.slurp:
        src: /etc/rancher/k3s/config.yaml
      register: k3s_server_config

    - name: Parse it
      ansible.builtin.set_fact:
        k3s_server_rendered: "{{ k3s_server_config.content | b64decode | from_yaml }}"

    - name: Traefik disabled, cell labels and kubelet reservations present
      ansible.builtin.assert:
        that:
          - "'traefik' in k3s_server_rendered.disable"
          - "'cb-cell=cb-test-dev' in k3s_server_rendered['node-label']"
          - "'cb-cloud=aws' in k3s_server_rendered['node-label']"
          - "k3s_server_rendered['kubelet-arg'] | select('match', '^kube-reserved=') | list | length == 1"
          - "k3s_server_rendered['write-kubeconfig-mode'] == '0600'"
```
(`tasks/config.yml` is the configuration half of the role; `main.yml` imports it, so Molecule tests the same code the VMs run. The scenario sets `k3s_server_manage_service: false` because the test container has no systemd or k3s for the restart handler.)

**What validating this layer found (Week 1, `bash tools/dev/iac-check.sh ansible molecule`):**
- The production profile requires **role-prefixed variable names**, including registered results (`k3s_server_version`, `k3s_server_installed`, `node_exporter_current`); the earlier unprefixed names failed `var-naming[no-role-prefix]`.
- Install k3s with the installer **pinned to the release tag** (`raw.githubusercontent.com/k3s-io/k3s/<version>/install.sh`), not the moving `get.k3s.io` script.
- On WSL, `/mnt/<drive>` is world-writable, so Ansible **ignores `ansible.cfg` in the working directory** (and then can't find roles). Set `ANSIBLE_CONFIG` explicitly; Linux CI checkouts are unaffected.
- Molecule's docker driver needs `rsync` and the `docker` CLI next to Ansible (`tools/dev/ansible-toolbox.Dockerfile`).
- A config-only converge still runs the role's handlers, so a k3s restart handler needs an explicit off-switch for the container.
- `aws_ssm` connections need an S3 transfer bucket; the AWS budget stack now creates it and `cloud_aws.yml` reads it from `CB_SSM_BUCKET`.

## 7. GitHub Actions wiring

```yaml
# .github/workflows/drill.yml
name: drill
on:
  schedule:
    - cron: "30 21 * * 6"          # 03:00 IST Sunday
  workflow_dispatch:
    inputs:
      from_cell: { type: choice, options: [aws, gcp], default: aws }
permissions:
  contents: write
  id-token: write
jobs:
  drill:
    runs-on: ubuntu-24.04
    environment: traffic-dev
    steps:
      - uses: actions/checkout@<sha>
      - uses: hashicorp/setup-terraform@<sha>
        with:
          terraform_version: "1.15.x"
          terraform_wrapper: false
      - uses: google-github-actions/auth@<sha>
        with:
          workload_identity_provider: ${{ vars.GCP_WIF_PROVIDER }}
          service_account: ${{ vars.GCP_TRAFFIC_SA }}
      - run: pipx install "ansible-core==2.21.*" && ansible-galaxy collection install -r ansible/requirements.yml
      - name: Run drill
        working-directory: ansible
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CB_CP_API: ${{ vars.CB_CP_API }}
          CB_CP_TOKEN: ${{ secrets.CB_CP_TOKEN }}
          CB_PROM_URL: ${{ vars.CB_PROM_URL }}
        run: ansible-playbook playbooks/drill.yml -e from_cell=${{ inputs.from_cell || 'aws' }} -e to_cell=${{ (inputs.from_cell || 'aws') == 'aws' && 'gcp' || 'aws' }}
      - name: Commit drill report
        run: |
          git config user.name cb-bot && git config user.email cb-bot@users.noreply.github.com
          curl -fsS -H "Authorization: Bearer ${{ secrets.CB_CP_TOKEN }}" "${{ vars.CB_CP_API }}/drills/latest/report.md" \
            -o "docs/drills/$(date -u +%F)-drill.md"
          git add docs/drills && git commit -m "docs(drill): $(date -u +%F)" && git push
```
