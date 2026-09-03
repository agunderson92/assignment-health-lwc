import { LightningElement } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getEngagementsPage from '@salesforce/apex/EngagementBurnController.getEngagementsPage';

const COLUMNS = [
    { label: 'Account', fieldName: 'accountName', wrapText: true, sortable: true },
    { label: 'Engagement', fieldName: 'name', wrapText: true, sortable: true,
      cellAttributes: { class: { fieldName: 'statusClass' } } },
    { label: 'Manager', fieldName: 'managerName', wrapText: true, sortable: true },
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

const PAGE_SIZE = 20;

export default class AllEngagementsBurn extends NavigationMixin(LightningElement) {
    columns = COLUMNS;
    rows = [];
    error;
    loading = false;

    pageNumber = 1;
    pageSize = PAGE_SIZE;
    totalCount = 0;
    totalPages = 0;

    managerUserId = null;
    accountId = null;

    // Default: highest revenue at risk first (applies within the current page)
    sortedBy = 'revenueAtRisk';
    sortDirection = 'desc';

    connectedCallback() {
        this.load();
    }

    load() {
        this.loading = true;
        getEngagementsPage({
            managerUserId: this.managerUserId,
            accountId: this.accountId,
            pageSize: this.pageSize,
            pageNumber: this.pageNumber
        })
            .then((res) => {
                const mapped = (res.rows || []).map((e) => ({
                    ...e,
                    statusClass: this.statusClass(e.status)
                }));
                this.rows = sortData(mapped, this.sortedBy, this.sortDirection);
                this.totalCount = res.totalCount;
                this.totalPages = res.totalPages;
                this.pageNumber = res.pageNumber;
                this.error = undefined;
            })
            .catch((err) => {
                this.error = err;
                this.rows = [];
            })
            .finally(() => {
                this.loading = false;
            });
    }

    statusClass(status) {
        switch (status) {
            case 'On track': return 'slds-text-color_success';
            case 'At risk':  return 'slds-text-color_error';
            default:         return 'slds-text-color_warning';
        }
    }

    handleAccountChange(event) {
        this.accountId = event.detail.recordId || null;
        this.pageNumber = 1;
        this.load();
    }

    handleManagerChange(event) {
        this.managerUserId = event.detail.recordId || null;
        this.pageNumber = 1;
        this.load();
    }

    handleClear() {
        this.accountId = null;
        this.managerUserId = null;
        this.pageNumber = 1;
        this.template.querySelectorAll('lightning-record-picker').forEach((p) => p.clearSelection());
        this.load();
    }

    handlePrev() {
        if (this.pageNumber > 1) {
            this.pageNumber -= 1;
            this.load();
        }
    }

    handleNext() {
        if (this.pageNumber < this.totalPages) {
            this.pageNumber += 1;
            this.load();
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

    get hasRows() {
        return this.rows && this.rows.length > 0;
    }
    get showEmpty() {
        return !this.loading && !this.error && (!this.rows || this.rows.length === 0);
    }
    get isFirstPage() {
        return this.pageNumber <= 1;
    }
    get isLastPage() {
        return this.pageNumber >= this.totalPages;
    }
    get pageLabel() {
        if (!this.totalCount) return 'No engagements';
        return `Page ${this.pageNumber} of ${this.totalPages} · ${this.totalCount} engagements`;
    }
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
