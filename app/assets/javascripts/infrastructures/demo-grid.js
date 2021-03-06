var wrap = require('modules/wrap');
var listen = require('modules/listen');
var queryString = require('query-string').parse(location.search);

// register the grid component
module.exports = Vue.extend({
  template: '#grid-template',
  replace: true,
  props: {
    data: Array,
    columns: Array,
    filterKey: String
  },

  data: function () {
    var sortOrders = {};
    this.columns.forEach(function (key) {
      sortOrders[key] = 1;
    });
    return {
      sortKey: '',
      sortOrders: sortOrders,
      loading: true,
      option: ['infrastructure'],
      lang: queryString.lang,
      pages: 10,
      pageNumber: 0,
      filteredLength: null,
    };
  },

  methods: {
    sortBy: function (key) {
      if(key !== 'id')
        this.sortKey = key;
      this.sortOrders[key] = this.sortOrders[key] * -1;
    },

    showPrev: function(){
      if(this.pageNumber === 0) return;
      this.pageNumber--;
    },

    showNext: function(){
      if(this.isEndPage) return;
      this.pageNumber++;
    },

    fetch_infras: function(){
      var self = this;
      self.loading = true;
      var id =  queryString.project_id;
      var monthNames = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
      ];
      $.ajax({
        cache: false,
        url:'/infrastructures?&project_id='+id,
      }).done(function (data) {
        this.pages = data.length;
        var nextColumns = [];
        self.data = data.map(function (item) {
          var d = new Date(item.created_at);
          var date = monthNames[d.getUTCMonth()]+' '+d.getDate()+', '+d.getFullYear()+' at '+d.getHours()+':'+d.getMinutes();
          if(item.project_id > 3){
            return {
              stack_name: item.stack_name,
              region: item.region,
              keypairname: item.keypairname,
              created_at: date,
              //  ec2_private_key_id: item.ec2_private_key_id,
              status: item.status,
              id: [item.id,item.status],
            };
          }else{
            return {
              stack_name: item.stack_name,
              region: item.region,
              keypairname: item.keypairname,
              //  ec2_private_key_id: item.ec2_private_key_id,
              id: [item.id,item.status],
            };
          }
          self.loading = false;
        });
        self.$emit('data-loaded');
        $("#loading").hide();
        var empty = t('infrastructures.msg.empty-list');
        if(self.data.length === 0){ $('#empty').show().html(empty);}
        self.filteredLength = data.length;
      });
    }
  },

  computed: {
    isStartPage: function(){
      return (this.pageNumber === 0);
    },
    isEndPage: function(){
      return ((this.pageNumber + 1) * this.pages >= this.data.length);
    },
  },
  created: function (){
    this.fetch_infras();
  },

  filters:{
    wrap: wrap,
    listen: listen,
    paginate: function(list) {
      var index = this.pageNumber * this.pages;
      return list.slice(index, index + this.pages);
    },
    roundup: function (val) { return (Math.ceil(val));},
    count: function (arr) {
      // record length
      this.$set('filteredLength', arr.length);
      // return it intact
      return arr;
    },
  },
});
