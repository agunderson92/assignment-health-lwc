import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getMyPortfolio from '@salesforce/apex/EngagementBurnController.getMyPortfolio';

const COLUMNS = [
    { label: 'Engagement', fieldName: 'name', wrapText: true, sortable: true,
      cellAttributes: { class: { fieldName: 'statusClass' } } },
    { label: 'Model', fieldName: 'model', fixedWidth: 90, sortable: true },
    { label: '% Cons.', fieldName: 'pctConsumed', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: '% Elap.', fieldName: 'pctComplete', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Worked', fieldName: 'worked', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'Forecast', fieldName: 'forecast', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'Run-rate', fieldName: 'runRate', type: 'number', sortable: true,
      typeAttributes: { maximumFractionDigits: 1 }, cellAttributes: { alignment: 'right' } },
    { label: 'Proj. undel. (hr)', fieldName: 'projUndeliveredHrs', type: 'number', sortable: true, cellAttributes: { alignment: 'right' } },
    { label: 'Rev. at risk', fieldName: 'revenueAtRisk', type: 'currency', sortable: true,
      typeAttributes: { currencyCode: 'USD', maximumFractionDigits: 0 }, cellAttributes: { alignment: 'right' } },
    { label: 'Status', fieldName: 'status', sortable: true, cellAttributes: { class: { fieldName: 'statusClass' } } },
    { type: 'button-icon', fixedWidth: 40,
      typeAttributes: { iconName: 'utility:new_window', title: 'Open in new tab', name: 'open', variant: 'bare' } }
];

export default class MyPortfolioBurn extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    rows;
    error;

    // Default: highest revenue at risk first
    sortedBy = 'revenueAtRisk';
    sortDirection = 'desc';

    @wire(getMyPortfolio)
    wired({ data, error }) {
        if (data) {
            const mapped = data.map((e) => ({ ...e, statusClass: this.statusClass(e.status) }));
            this.rows = sortData(mapped, this.sortedBy, this.sortDirection);
            this.error = undefined;
        } else if (error) {
            this.error = error;
        }
    }

    statusClass(status) {
        switch (status) {
            case 'On track': return 'slds-text-color_success';
            case 'At risk':  return 'slds-text-color_error';
            default:         return 'slds-text-color_warning';
        }
    }

    handleSort(event) {
        this.sortedBy = event.detail.fieldName;
        this.sortDirection = event.detail.sortDirection;
        this.rows = sortData(this.rows, this.sortedBy, this.sortDirection);
    }

    handleRowAction(event) {
        const id = event.detail.row.engagementId;
        this[NavigationMixin.GenerateUrl]({
            type: 'standard__recordPage',
            attributes: { recordId: id, objectApiName: 'KimbleOne__DeliveryGroup__c', actionName: 'view' }
        }).then((url) => {
            window.open(url, '_blank');
        });
    }

    get hasRows() { return this.rows && this.rows.length > 0; }
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
