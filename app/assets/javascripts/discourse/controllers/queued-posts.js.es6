import { propertyEqual } from 'discourse/lib/computed';
import { popupAjaxError } from 'discourse/lib/ajax-error';

export default Ember.Controller.extend({
  queryParams: ['state', 'limit'],
  state: 'new',
  limit: 100
});
