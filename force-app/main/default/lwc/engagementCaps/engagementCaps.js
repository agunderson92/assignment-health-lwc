import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getEngagementCaps from '@salesforce/apex/EngagementBurnController.getEngagementCaps';

const COLUMNS = [
    { label: 'Element', fieldName: 'elementName', wrapText: true, sortable: true },
    { label: 'Activity', fieldName: 'activityName', wrapText: true, sortable: true,
      cellAttributes: { class: { fieldName: 'statusClass' } } },
    { label: 'Cap', fieldName: 'cap', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: 'Consumed', fieldName: 'consumed', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: '% of cap cons.', fieldName: 'consumedPct', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Forecast', fieldName: 'forecast', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: '% of cap fcst.', fieldName: 'forecastPct', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Projected overage', fieldName: 'overage', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: 'Status', fieldName: 'status', sortable: true, cellAttributes: { class: { fieldName: 'statusClass' } } },
    { type: 'button-icon', fixedWidth: 40,
      typeAttributes: { iconName: 'utility:new_window', title: 'Open activity in new tab', name: 'open', variant: 'bare' } }
];

export default class EngagementCaps extends NavigationMixin(LightningElement) {
    @api recordId;
    columns = COLUMNS;
    rows;
    error;

    // Default: highest projected % of cap first
    sortedBy = 'forecastPct';
    sortDirection = 'desc';

    @wire(getEngagementCaps, { engagementId: '$recordId' })
    wired({ data, error }) {
        if (data) {
            const mapped = data.map((c) => ({ ...c, statusClass: this.statusClass(c.status) }));
            this.rows = sortData(mapped, this.sortedBy, this.sortDirection);
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    statusClass(status) {
        switch (status) {
            case 'Over cap': return 'slds-text-color_error';
            case 'At risk':  return 'slds-text-color_error';
            case 'On track': return 'slds-text-color_success';
            default:         return 'slds-text-color_warning'; // Watch / Under-running
        }
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;
        this.rows = sortData(this.rows, this.sortedBy, this.sortDirection);
    }

    handleRowAction(event) {
        const id = event.detail.row.activityId;
        this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: 'KimbleOne__ResourcedActivity__c', actionName: 'view' }
        }).then((url) => {
            window.open(url, '_blank');
        });
    }

    get hasRows() { return this.rows && this.rows.length > 0; }
    get showEmpty() { return this.rows && this.rows.length === 0; }
}

/** Stable client-side sort; nulls always sort last regardless of direction. */
function sortData(rows, field, direction) {
    const factor = direction === 'asc' ? 1 : -1;
    const cloned = [...rows];
    cloned.sort((a, b) => {
        let x = a[field];
        let y = b[field];
        if (x == null && y == null) return 0;
        if (x == null) return 1;
        if (y == null) return -1;
        if (typeof x === 'string') { x = x.toLowerCase(); y = String(y).toLowerCase(); }
        if (x > y) return factor;
        if (x < y) return -factor;
        return 0;
    });
    return cloned;
}
