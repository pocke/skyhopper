#
# Copyright (c) 2013-2015 SKYARCH NETWORKS INC.
#
# This software is released under the MIT License.
#
# http://opensource.org/licenses/mit-license.php
#

# Zabbix API Wrapper.
#
# physical_id を host の名前として扱う。
class Zabbix
  DefaultUsergroupName = "No access to the frontend"
  MasterUsergroupName = "master"

  class ConnectError < StandardError; end

  # @param [String] username
  # @param [String] password
  # @raise [ConnectError] if cannot connect zabbix, raise this.
  def initialize(username, password)
    s = AppSetting.get
    url = "http://#{s.zabbix_fqdn}/zabbix/api_jsonrpc.php"

    opt = {url: url, user: username, password: password}
    opt[:debug] = true if Rails.env.development?

    begin
      @zabbix = ZabbixApi.connect(opt)
      @sky_zabbix = SkyZabbix::Client.new(url, logger: Rails.logger)
      @sky_zabbix.login(username, password)
    rescue => ex
      raise ConnectError, ex.message
    end
  end

  # ホストが存在するかをbooleanで返す
  # @param [String] physical_id
  # @return [TrueClass|FalseClass]
  def host_exists?(physical_id)
    return !!get_host_id(physical_id)
  end

  # user が存在するかを返す。
  # @param [String] user_name Email address of SkyHopper user
  # @return [TrueClass|FalseClass]
  def user_exists?(user_name)
    return !!@zabbix.users.get_id(alias: user_name)
  end

  # ホストにテンプレートを追加する
  # @param [String] physical_id
  # @param [Array<String>] テンプレートの名前の配列
  def templates_link_host(physical_id, template_names)
    host_id = get_host_id(physical_id)
    template_ids = @zabbix.query(method: 'template.get', params: {filter: {host: template_names}}).map{|x|x['templateid']}

    @zabbix.templates.mass_add(hosts_id: [host_id], templates_id: template_ids)
  end

  # トリガーのオンオフを切り替える
  # @param [Infrastructure] infra
  # @param [Array<String>]  item_keys 監視項目で選ばれたアイテム
  def switch_trigger_status(infra, item_keys)
    all_triggers = get_triggers_for_infra(infra)

    if item_keys.empty?
      disable_trigger(all_triggers)
      return
    end

    # 選択されているtriggerのIDを全て取得する。
    # インフラのリソース毎に行っている。トリガーのIDが異なる為
    selected_triggerids = []
    infra.resources.each do |r|
      # データベースにはitemkeyとしてmysql.loginが保存されているので
      # 実際にitemkeyとして設定されている値をzabbixから取ってきて
      # replaceしています
      if idx = item_keys.index('mysql.login')
        item_keys[idx] = get_item_info(r.physical_id, 'mysql.login', "search").first["key_"]
      end

      item_infos = get_item_info(r.physical_id, item_keys, "filter")
      item_infos.each do |item|
        # もしアイテムをZabbixに足したなら必ずそれに紐づくトリガーも作成して下さい
        # ここでエラーを吐きます↓
        selected_triggerids.push(item["triggers"].first["triggerid"])
      end
    end

    # すべてのtriggerを一旦Enableにし、選択されていないTriggerをすべてDisableにする。
    # ZabbixとSkyHopperの整合性を保つため。
    enable_trigger(selected_triggerids)
    unselected_triggerids = all_triggers.reject{|trigger| selected_triggerids.include?(trigger)}
    disable_trigger(unselected_triggerids)
  end

  # TODO コメント
  # trigger_exprs => {item_key: expression}
  def update_trigger_expression(infra, trigger_exprs)
    infra.resources.ec2.each do |r|
      item_infos = get_item_info(r.physical_id, trigger_exprs.keys, "filter")
      item_infos.each do |item|
        updating_expr = trigger_exprs[item["key_"]].sub("HOSTNAME", r.physical_id)
        update_expression(item["triggers"].first["triggerid"], updating_expr)
      end
    end
  end

  def update_expression(trigger_id, expression)
    @zabbix.query(
      method: "trigger.update",
      params: {
        expression: expression,
        triggerid: trigger_id
      }
    )
  end

  # mysqlのアイテムキーとトリガーをアップデートしています
  def update_mysql(infra, fqdn)
    key = "mysql.login"
    infra.resources.ec2.each do |r|
      item_infos = get_item_info(r.physical_id, key, "search")
      if fqdn
        host_key = "[" + fqdn + "]"
      else
        host_key = ""
      end

      @zabbix.query(
        method: "item.update",
        params: {
          itemid: item_infos.first["itemid"],
          key_: key + host_key
        }
      )

      expression = "{#{r.physical_id}:mysql.login#{host_key}.last(0)}=1"
      update_expression(item_infos.first["triggers"].first["triggerid"], expression)
    end
  end

  # @param [String] hostname physical_id
  # @return [Array<Hash>]  item_key => trigger_expression
  def get_trigger_expressions_by_hostname(hostname)
    data = @sky_zabbix.trigger.get(
      output: [
        "triggeid",
        "expression"
      ],
      filter: {
        host: hostname
      },
      expandExpression: true,
      selectItems: [:key_]
    )

    # ホストネームの部分をHOSTNAMEと置換えている
    # ビュー側でトリガーの現在値を取り出す為
    # infra.js edit monitoring component created 参照
    expression_hash = {}
    data.each do |data|
      data["expression"][/\{(i-[a-z0-9]+):/, 1] = "HOSTNAME"
      expression_hash[data["items"].first["key_"]] = data["expression"]
    end

    return expression_hash
  end

  # Zabbix Serverにホストを登録する。
  # もしホストグループが存在しなければ、対応するグループを作成する。
  # @param [Infrastructure] infra
  # @param [String] physical_id
  def create_host(infra, physical_id)
    ec2 = infra.ec2.instances[physical_id]
    hostgroup_id = get_hostgroup_id(infra.project.code)

    @zabbix.hosts.create(
      host: physical_id,
      interfaces: [{
        type: 1,
        main: 1,
        ip: ec2.elastic_ip || ec2.public_ip_address,
        dns: ec2.public_dns_name,
        port: 10050,
        useip: 0
      }],
      groups: [
        groupid: hostgroup_id
      ]
    )
  end

  # ウェブシナリオ用に新しくホストを作ります。
  # インフラ下の全てのウェブシナリオをこのホストで管理する為(ELB)
  # @param [Infrastructure] infra
  def create_elb_host(infra)
    hostgroup_id = get_hostgroup_id(infra.project.code)

    @zabbix.hosts.create(
      host: infra_to_elb_hostname(infra),
      interfaces: [{
        type: 1,
        main: 1,
        useip: 1,
        ip: "127.0.0.1",
        dns: "",
        port: "10050"
      }],
      groups: [
        groupid: hostgroup_id
      ]
    )
  end

  # ホストグループを作成する。作成したホストグループのIDを返す。
  # @param [String] group_name
  # @return [String] ID of created hostgroup
  def add_hostgroup(group_name)
    return @zabbix.query(
      method: 'hostgroup.create',
      params: {
        name: group_name
      }
    )["groupids"].first
  end

  PermissionAccessDenied = 0
  PermissionRead         = 2
  PermissionReadWrite    = 3
  # User Group を作成する。
  # @param [String] group_name     作成するUserGroupの名前
  # @param [Integer] host_group_id 権限を与えるホストグループのID
  # @param [Integer] permission    与える権限の種類。 PermissionRead, PermissionRead or PermissionReadWrite.
  # @return [String] ID of created usergroup.
  def create_usergroup(group_name, host_group_id = nil, permission = nil)
    q = {
      method: 'usergroup.create',
      params: {
        name: group_name,
      }
    }
    if host_group_id
      q[:params][:rights] = {
        permission: permission,
        id: host_group_id,
      }
    end

    return @zabbix.query(q)["usrgrpids"].first
  end

  # master usergroup が読み取り権限を持つホストグループを、hostgroup_ids に変更する。
  # @param [Array] hostgroup_ids master usergroup が読み取れるようにする hostgroup の ID 一覧
  def change_mastergroup_rights(hostgroup_ids)
    @zabbix.query(
      method: "usergroup.massupdate",
      params: {
        usrgrpids: [get_master_usergroup_id],
        rights: hostgroup_ids.map{|id| {permission: PermissionRead, id: id}}
      }
    )
  end

  # @param [String] group_name
  def delete_usergroup(group_name)
    usergroup_id = get_usergroup_ids(group_name)
    @zabbix.query(
      method: 'usergroup.delete',
      params: usergroup_id
    )
  end

  # グループIDの配列を返す
  # 引数のgroup_nameは配列で複数OK
  def get_usergroup_ids(group_name)
    usergroup_info = @zabbix.query(
      method: 'usergroup.get',
      params: {
        filter: {
          name: group_name
        }
      }
    )

    usergroup_ids = usergroup_info.map{|info| info["usrgrpid"]}
    return usergroup_ids
  end

  # @param [String] group_name
  def delete_hostgroup(group_name)
    hostgroup_id = get_hostgroup_id(group_name)
    @zabbix.query(
      method: 'hostgroup.delete',
      params: [hostgroup_id]
    )
  end

  # hostname string/array
  # hostgroupの名前の一覧から、hostgroupのIDの配列を返す。
  def get_hostgroup_ids(hostgroup_names)
    hostgroup_info = @zabbix.query(
      method: 'hostgroup.get',
      params: {
        output: 'extend',
        filter: {
         name: hostgroup_names
        }
      }
    )

   return hostgroup_info.map{|i| i["groupid"]}
  end

  def get_hostgroup_id(group_name)
    return get_hostgroup_ids(group_name).first
  end

  # @param [User] User of SkyHopper
  # @return [String] ID of created user
  def create_user(user)
    type  = get_user_type_by_user(user)
    group = get_group_id_by_user(user)

    return @zabbix.query(
      method: 'user.create',
      params: {
        alias: user.email,
        passwd: user.encrypted_password,
        usrgrps: [
          usrgrpid: group,
        ],
        type: type,
      },
    )['userids'].first
  end

  def get_user_id(username)
    user_info = @zabbix.query(
      method: 'user.get',
      params: {
        filter: {
          alias: username
        }
      }
    )

    return user_info.first['userid']
  end

  UserTypeDefault    = 1
  UserTypeAdmin      = 2
  UserTypeSuperAdmin = 3
  # Zabbix上のユーザを指定したユーザーグループに移動する。またUserTypeを変更する。
  # @param [String] user_id ID of Zabbix user
  # @param [Array<String>] usergroup_ids
  # @param [Integer] type
  # @param [String] password
  def update_user(user_id, usergroup_ids: nil, type: UserTypeDefault, password: nil)
    @zabbix.query(
      method: 'user.update',
      params: {
        userid:  user_id,
        usrgrps: usergroup_ids,
        passwd:  password,
        type:    type,
      }
    )
  end

  def delete_user(username)
    @zabbix.query(
      method: 'user.delete',
      params: [get_user_id(username)]
    )
  end

  # master usergroupのIDを返す。もし master usergroup が存在しなければ usergroup を作成する。
  # ==== return
  # usergroup ID (Integer)
  def get_master_usergroup_id
    @@master_usergroup_id ||= (get_usergroup_ids(MasterUsergroupName).first || create_usergroup(MasterUsergroupName))
  end

  def get_default_usergroup_id
    @@default_usergroup_id ||= get_usergroup_ids(DefaultUsergroupName).first
  end

  # @param [User] user is a Skyhopper user.
  def get_group_id_by_user(user)
    if user.master? and not user.admin?
      return get_master_usergroup_id
    else
      return get_default_usergroup_id
    end
  end

  # @param [User] user is a Skyhopper user.
  def get_user_type_by_user(user)
    if user.master? and user.admin?
      return UserTypeSuperAdmin
    else
      return UserTypeDefault
    end
  end

  #Item_keyはItemの情報を得る為に使われる
  #返される値はGoogle Chart用のフォーマットに変更された
  #アイテムのヒストリー情報
  def get_history(physical_id, item_key)
    item_info = get_item_info(physical_id, item_key, "filter")

    # データによってオブジェクトのタイプが違う
    # 3 integer, 0 float
    type = case item_key
           when "vm.memory.size[available]", "net.tcp.service[http]", "net.tcp.service[smtp]"
             3
           else
             0
           end

    history_all =  @zabbix.query(
      method: 'history.get',
      params: {
        output: "extend",
        history: type,
        itemids: item_info.first["itemid"],
        sortfield: 'clock',
        sortorder: 'DESC',
        limit: 30
      }
    )

    # chart_data: ([time, value], [time, value])
    chart_data = []
    history_all.each do |history|
      time = Time.at(history["clock"].to_i)
      chart_data.push([time.strftime("%H:%M"), history["value"].to_f])
    end
    return chart_data
  end

  # 最近の障害を取ってきている
  # View側でテーブル表示する為のフォーマットを作って
  # 値を返している
  def show_recent_problems(infra)
    problems = @zabbix.query(
      method: "trigger.get",
      params: {
        output: [
          :triggerid,
          :description,
          :priority,
          :lastchange,
          :value,
        ],
        sortfield: "lastchange",
        selectHosts: "refer",
        only_true: true,
        monitored: true
      }
    )

    ids = infra.resources.ec2.map{|ec2| ec2.physical_id }

    #TODO
    #ホストネームに基づいたProblemsのみを取得して
    #フォーマッティングする

    # フォーマッティング
    problems.each do |p|
      time = Time.at(p["lastchange"].to_i)
      p["hosts"] = p["hosts"].first["hostid"]
      p["lastchange"] = time.strftime("%Y-%m-%d %H:%M:%S")
      hostname = get_host_name(p["hosts"])
      p["description"] = p["description"].sub(/{HOST.NAME}/, hostname.first["name"])
    end

    # 関係のある障害のみ表示する
    data_for_table = []
    ids.each do |id|
      problems.each do |p|
        data_for_table.push(p) if p["description"] =~ /#{id}$/
      end
    end

    return data_for_table
  end

  # web_scenario [[stepname, url, required_string, status_code, timeout]]
  def create_web_scenario(infra, web_scenario)
    host_id = get_host_id(infra_to_elb_hostname(infra))
    web_scenario_ids = get_web_scenario_id(host_id)

    # Web Scenarioを作る前に一度ホスト名に紐付いた全てのシナリオを削除する
    # Web Scenario名の重複を防ぐため、ステップの重複を防ぐ為
    delete_all_web_scenario(web_scenario_ids) if web_scenario_ids

    #TODO ウェブシナリオ名が被っている場合の処理
    if web_scenario.blank?
      return
    end

    wh = {}
    web_scenario.each do |w|
      scenario_name = w.shift
      if wh.has_key?(scenario_name)
        wh[scenario_name] << w
      else
        wh[scenario_name] = [w]
      end
    end

    # wh = {scenario_name => [[steps], [steps]]}
    wh.each do |scenario_name, steps|
      step_category = [:name, :url, :required, :status_codes, :timeout, :no]

      # [{name: "NAME", url: "http://...", ..., no: 1..n}]
      s_array = steps.map.with_index(1) do |step, i|
        step.push(i)
        step_category.zip(step).to_h
      end

      @zabbix.query(
        method: "httptest.create",
        params: {
          name:  scenario_name,
          hostid: host_id,
          steps: s_array
        }
      )
    end
  end

  # Zabbix上の関係  host has many scenarios. web scenario has many steps
  # ホストに紐づく全てのウェブシナリオを取得し、
  # それに紐づくステップを全て取得し返す
  # hostname = project.code
  def all_web_scenarios(infra)
    host_id = get_host_id(infra_to_elb_hostname(infra))
    data_all = get_all_web_scenarios(host_id)

    return [] if data_all.blank?

    web_scenario_values = []
    data_all.each do |scenario|
      scenario["steps"].each do |step|
        values = [scenario["name"]]
        ["name", "url", "required", "status_codes", "timeout"].map do |x|
          values.push(step[x])
        end

        web_scenario_values.push(values)
      end
    end

    return web_scenario_values
  end

  def get_url_status_monitoring(infra)
    host_id = get_host_id(infra_to_elb_hostname(infra))
    items = @zabbix.query(
      method: "item.get",
      params: {
        hostids: host_id,
        output: [
          "key_",
          "lastvalue",
        ],
        webitems: "true"
      }
    )

    webscenario = @zabbix.query(
      method: "httptest.get",
      params: {
        hostids: host_id,
        selectSteps: [
          "name",
          "url"
        ],
        output: ["name"]
      }
    )

    data_for_table = []
    webscenario.each do |scenario|

      # アイテム名がシナリオ名にマッチするアイテムを取り出しています
      # また、取り出したアイテム名にFailとErrorを含むアイテムを取り出し、Hashに格納
      h = {}
      items_for_scenario = items.select{|x| x["key_"][/^web\.test\.\w+\[(\w[\w\s]*(?<!\s)),?.*\]$/, 1] == scenario["name"]}
      ["error", "fail"].each do |key|
        h[key] = items_for_scenario.find{|x| x["key_"] =~ /^web\.test\.#{key}\[/}
      end

      case h["fail"]["lastvalue"]
      when "0"
        status = "OK"
      else
        status = h["error"]["lastvalue"]
      end

      # 上で取り出したアイテムにレスポンドコードを含むモノを取り出し、
      # URLとレスポンドコードとダウンロードスピード (bytes/sec) をstep_valuesに格納
      step_values = []
      scenario["steps"].each do |step|

        rspcode_item, download_speed_item, response_time_item = ["rspcode", "in", "time"].map do |c|
          items_for_scenario.find{|x| x["key_"][/^web\.test\.#{c}\[\w[\w\s]*(?<!\s),?(\w*),?.*\]$/, 1] == step["name"]}
        end

        # もしデータが存在しない場合は""Unknownに設定する
        rspcode = rspcode_item.present? ? rspcode_item["lastvalue"] : "Unknown"
        download_speed = download_speed_item.present? ? download_speed_item["lastvalue"].to_i.round : "Unknown"
        response_time = response_time_item.present? ? response_time_item["lastvalue"] : "Unknown"
        step_values.push({url: step["url"], response_code: rspcode, download_speed: download_speed, response_time: response_time})
      end

      data_for_table.push({name: scenario["name"], status: status, data: step_values})
    end

    # data_for_table = [{name: "hoge",  status: "OK", data: [{url: hoge.com, response_code: "200", download_speed: fuga, response_time: hoge}]}]
    return data_for_table
  end

  # MySQL監視の為のベースとなるアイテムを作成します
  def create_mysql_login_item(physical_id)
    host_id = get_host_id(physical_id)
    application_ids = get_application_ids_by_names(["MySQL"], host_id)
    interfaceid = get_hostinterface_id(host_id)

    @zabbix.query(
      method: "item.create",
      params: {
        name: "Original Item: MySQL Login Check",
        key_: "mysql.login",
        hostid: host_id,
        delay: 60,
        type: 0,
        value_type: 0,
        applications: application_ids,
        interfaceid: interfaceid
      }
    )
  end

  def create_mysql_login_trigger(item_info, physical_id)
    item_id = item_info["itemids"].first

    @zabbix.query(
      method: "trigger.create",
      params: {
        description: "Can not login MySQL on {HOST.NAME}",
        expression: "{#{physical_id}:mysql.login.last(0)}=1",
        itemid: item_id
      }
    )
  end

  # ホスト登録時にCPU用に新しいアイテムを作成します
  def create_cpu_usage_item(physical_id)
    host_id = get_host_id(physical_id)
    application_ids = get_application_ids_by_names(["CPU", "Performance"], host_id)

    @zabbix.query(
      method: "item.create",
      params: {
        name: "Original Item: CPU Total Usage",
        key_: "system.cpu.util[,total,avg1]",
        params: %Q[100-last("system.cpu.util[,idle]")],
        hostid: host_id,
        delay: 30,
        type: 15,
        value_type: 0,
        applications: application_ids,
        units: "%"
      }
    )
  end

  # ホスト登録時にCPU用の新しいアイテムを作成したので、
  # それに紐づくトリガーを作成する
  def create_cpu_usage_trigger(item_info, hostname)
    id = item_info["itemids"].first

    @zabbix.query(
      method: "trigger.create",
      params: {
        description: "Calculated: CPU Usage is too high on {HOST.NAME}",
        expression: "{#{hostname}:system.cpu.util[,total,avg1].last(0)}>90",
        itemid: id
      }
    )
  end

  def delete_hosts(host_ids)
    @zabbix.query(
      method: "host.delete",
      params: host_ids
    )
  end

  def delete_hosts_by_infra(infra)
    host_names = infra.resources.ec2.pluck(:physical_id)
    host_names.push(infra_to_elb_hostname(infra))
    host_ids = get_host_ids(host_names).compact
    return if host_ids.empty?
    delete_hosts(host_ids)
  end

  # MySQL関連のアイテムを取得する際はkindが"search"になります
  # kind = search or filter
  def get_item_info(physical_id, item_keys, kind)
    @zabbix.query(
      method: 'item.get',
      params: {
        hostids: get_host_id(physical_id),
        :"#{kind}" => {
          key_: item_keys
        },
        output: [
          :key_
        ],
        selectTriggers: 'shorten'
      }
    )
  end

  def infra_to_elb_hostname(infra)
    return "#{infra.id}-#{infra.stack_name}-elb"
  end

  private

  # MySQLログイン監視のアイテムを作成する際に使います
  # returns interfaceid integer
  def get_hostinterface_id(host_id)
    interface_info = @zabbix.query(
      method: "hostinterface.get",
      params: {
        output: "extend",
        hostids: host_id
      }
    )

    return interface_info.first["interfaceid"]
  end

  def get_application_ids_by_names(names, host_id)
    application_ids = @zabbix.query(
      method: "application.get",
      params: {
        output: [:applicationid ],
        hostids: host_id,
        filter: {
          name: names
        }
      }
    )

    # アプリケーションIDの配列を返す
    return application_ids.map{|x| x["applicationid"]}
  end

  def delete_all_web_scenario(web_scenario_ids)
    @zabbix.query(
      method: "httptest.delete",
      params: web_scenario_ids
    )
  end

  def get_all_web_scenarios(host_id)
    @sky_zabbix.httptest.get(
      output: [:httptestid, :name],
      selectSteps: "extend",
      selectHosts: "hostid",
      selectItems: "extend",
      hostids: host_id.to_s
    )
  end

  def get_web_scenario_id(host_id)
    data = @zabbix.query(
      method: "httptest.get",
      params: {
        output: [:httptestid],
        hostids: host_id.to_s
      }
    )

    return data.present? ? data.map{|scenario| scenario["httptestid"]} : nil
  end

  # infra に紐付いた trigger のID一覧を返す。
  # @param [Infrastructure] infra
  # @return [Array<String>] Array of trigger ID
  def get_triggers_for_infra(infra)
    host_ids = infra.resources.ec2.map do |r|
      get_host_id(r.physical_id)
    end

    return @zabbix.query(
      method: 'trigger.get',
      params: {
        hostids: host_ids
      }
    ).map{|t|t['triggerid']}
  end

  # status = 0 はトリガーオン
  def enable_trigger(trigger_ids)
    trigger_ids_set_status = trigger_ids.map{|id| {triggerid: id, status: 0}}
    @zabbix.query(
      method: 'trigger.update',
      params: trigger_ids_set_status
    )
  end

  # status = 0 はトリガーオフ
  def disable_trigger(trigger_ids)
    trigger_ids_set_status = trigger_ids.map{|id| {triggerid: id, status: 1}}
    @zabbix.query(
      method: 'trigger.update',
      params: trigger_ids_set_status
    )
  end

  #get host name from given hostid
  def get_host_name(hostid)
    @zabbix.query(
      method: 'host.get',
      params: {
        hostids: hostid,
        output: [
          :name
        ]
      }
    )
  end

  # host idを返す。hostが存在しなければ nilを返す。
  # @param [String] physical_id
  # @return [String] host_id. example: "1"
  def get_host_id(physical_id)
    return @sky_zabbix.host.get_id(host: physical_id)
  end

  # host id の一覧を返す。
  # @param [Array<String>] host_names
  # @return [Array<String>] host_ids. example: ["1", "2"]
  def get_host_ids(host_names)
    @zabbix.query(method: 'host.get', params: {filter: {host: host_names}}).map{|x|x['hostid']}
  end
end
